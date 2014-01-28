
#
# A file that wraps the creation and management of test
# users, potentially with features to access test twitter 
# and github accounts. As such, it might need access to
# a configuration file, since we don't want to push our
# test twitter/github credentials to github.
#

{prng} = require 'crypto'
{init,config} = require './config'
path = require 'path'
iutils = require 'iced-utils'
{mkdir_p} = iutils.fs
{athrow} = iutils.util
{make_esc} = require 'iced-error'
log = require '../../lib/log'
gpgw = require 'gpg-wrapper'
{AltKeyRing} = gpgw.keyring
{run} = gpgw
keypool = require './keypool'
{Engine} = require 'iced-expect'
{tweet_api} = require './twitter'
{gist_api} = require './github'

#==================================================================

strip = (x) -> if (m = x.match /^(\s*)([\S\s]*?)(\s*)$/) then m[2] else x

#==================================================================

randhex = (len) -> prng(len).toString('hex')

#==================================================================

exports.User = class User

  constructor : ({@username, @email, @password, @homedir}) ->
    @keyring = null
    @_state = { proved : {} }
    @_proofs = {}
    users().push @

  #---------------

  @generate : () -> 
    base = randhex(3)
    opts =
      username : "test_#{base}"
      password : randhex(6)
      email    : "test+#{base}@test.keybase.io"
      homedir  : path.join(config().scratch_dir(), "home_#{base}")
    new User opts

  #-----------------

  init : (cb) ->
    esc = make_esc cb, "User::init"
    await @make_homedir esc defer()
    await @make_keyring esc defer()
    await @grab_key esc defer()
    await @write_config esc defer()
    @_state.init = true
    cb null

  #-----------------

  write_config : (cb) ->
    esc = make_esc cb, "User::write_config"
    await @keybase { args : [ "config" ], quiet : true }, esc defer()  
    args = [
      "config"
      "--json"
      "server"
      JSON.stringify(config().server_obj())
    ]
    await @keybase { args, quiet : true }, esc defer()
    cb null

  #-----------------

  make_homedir : (cb) ->
    await mkdir_p @homedir, null, defer err
    cb err

  #-----------------

  keyring_dir : () -> path.join(@homedir, ".gnupg")

  #-----------------

  _keybase_cmd : (inargs) -> 
    inargs.args = [ "--homedir", @homedir ].concat inargs.args
    config().keybase_cmd inargs
    return inargs

  #-----------------

  keybase : (inargs, cb) ->
    @_keybase_cmd inargs
    await run inargs, defer err, out
    cb err, out

  #-----------------

  keybase_expect : (args) ->
    inargs = { args }
    @_keybase_cmd inargs
    eng = new Engine inargs
    eng.run()
    return eng

  #-----------------

  make_keyring : (cb) ->
    await AltKeyRing.make @keyring_dir(), defer err, @keyring
    cb err

  #-----------------

  gpg : (args, cb) -> @keyring.gpg args, cb

  #-----------------

  grab_key : (cb) ->
    esc = make_esc cb, "User::grab_key"
    await keypool.grab esc defer tmp
    await tmp.load esc defer()
    @key = tmp.copy_to_keyring @keyring
    await @key.save esc defer()
    cb null

  #-----------------

  push_key : (cb) ->
    await @keybase { args : [ "push", @key.fingerprint() ], quiet : true }, defer err
    @_state.pushed = true unless err?
    cb err

  #-----------------

  signup : (cb) ->
    eng = @keybase_expect [ "signup" ]
    await eng.conversation [
        { expect : "Your desired username: " }
        { sendline : @username }
        { expect : "Your passphrase: " }
        { sendline : @password }
        { expect : "confirm passphrase: " }
        { sendline : @password },
        { expect : "Your email: "}
        { sendline : @email }
        { expect : "Invitation code: 123412341234123412341234" }
        { sendline : "" }
      ], defer err
    unless err?
      await eng.wait defer rc
      if rc isnt 0
        err = new Error "Command-line client failed with code #{rc}"
      else
        @_state.signedup = true
    cb err

  #-----------------

  prove : ({which, search_regex, http_action}, cb) ->
    esc = make_esc cb, "User::prove"
    eng = @keybase_expect [ "prove", which ]
    @twitter = {}
    unless (acct = config().get_dummy_account which)?
      await athrow (new Error "No dummy accounts available for '#{which}'"), esc defer()
    await eng.expect { pattern : (new RegExp "Your username on #{which}: ", "i") }, esc defer()
    await eng.sendline acct.username, esc defer()
    await eng.expect { pattern : (new RegExp "Check #{which} now\\? \\[Y/n\\] ", "i") }, esc defer data
    if (m = data.toString('utf8').match search_regex)?
      proof = m[1]
    else
      await athrow (new Error "Didn't get a #{which} text from the CLI"), esc defer()
    await http_action acct, proof, esc defer proof_id
    await eng.sendline "y", esc defer()
    await eng.wait defer rc
    if rc isnt 0
      err = new Error "Error from keybase prove: #{rc}"
    else 
      @_proofs[which] = { proof, proof_id, acct }
      @_state.proved[which] = true
    cb err

  #-----------------

  prove_twitter : (cb) ->
    opts = 
      which : "twitter"
      search_regex : /Please tweet the following:\s+(\S.*?)\n/
      http_action : tweet_api
    await @prove opts, defer err
    cb err

  #-----------------

  prove_github : (cb) ->
    opts = 
      which : "github"
      search_regex : /Please post a Gist with the following:\s+(\S[\s\S]*?)\n\nCheck GitHub now\?/i
      http_action : gist_api
    await @prove opts, defer err
    cb err

  #-----------------

  has_live_key : () -> @_state.pushed and @_state.signedup and not(@_state.revoked)

  #-----------------

  full_monty : (T, gcb) ->
    esc = (which, lcb) -> (err, args...) ->
      T.waypoint "fully_monty: #{which}"
      T.no_error err
      if err? then gcb err
      else lcb args...
    await @init esc('init', defer())
    await @signup esc('signup', defer())
    await @push_key esc('push_key', defer())
    await @prove_github esc('prove_github', defer())
    await @prove_twitter esc('prove_twitter', defer())
    gcb null

  #-----------------

  revoke_key : (cb) ->
    err = null
    if config().preserve
      log.warn "Not deleting key / preserving due to command-line flag"
    else
      await @keybase { args : [ "revoke", "--force" ], quiet : true }, defer err
      @_state.revoked = true unless err?
    cb err

#==================================================================

class Users

  constructor : () -> 
    @_list = [] 
    @_lookup = {}

  pop : () -> @_list.pop()

  push : (u) ->
    @_list.push u
    @_lookup[u.username] = u
  
  lookup : (u) -> @_lookup[u]

  cleanup : (cb) ->
    err = null
    for u in @_list when u.has_live_key()
      await u.revoke_key defer tmp
      if tmp?
        log.error "Error revoking user #{u.username}: #{tmp.message}"
        err = tmp
    cb err

#==================================================================

_users = new Users
exports.users = users = () -> _users

#==================================================================
