---
name: cmux-setup
description: Set up cmux for the user from one entry point: trust a folder, install or sign in an agent harness, add an ssh machine, update peers, accounts, Cloud machines, Tailscale, MCP wiring, Computer Use, browser import, key bindings, notifications, team invites. Use when the user asks to set up, connect, install, sign in or configure anything in cmux.
cmux-managed: true
---

# Set it up for the user

The user wants setup done for them, not explained to them. You run the
commands; the user is asked only for what a person must do themselves (an
OAuth sign-in in a browser, a secret, a macOS switch in System Settings),
and then for one click or one touch.

## 1. Find the task

`cmux setup list` prints every setup task as JSON:
`{id, summary, setup, check, apply, person}`.

- `setup`: the `cmux setup` command that runs it, when there is one. Prefer
  it: it checks first, changes nothing when the state is already right,
  and names its undo.
- `check`: read-only commands that report the state. Run one before you
  change anything.
- `apply`: the commands that do it today, when `setup` does not run it yet.
- `person`: what only the user can do. Hand them exactly that, nothing more.

`cmux setup status` checks every task `setup` runs, for the current folder.

## 2. Run it

Every `cmux setup` command prints one JSON object. Read `state`:

- `ok`: already set up. Say so in one line; do not run it again.
- `planned`: the `--dry-run` result. Run it without `--dry-run` to do it.
- `changed`: done. `undo` is the command that puts the old state back;
  keep it, and mention it when the user may want to reverse the change.
- `needs_user`: `user_action` says what the user must do (`text`, and a
  `command` or `url`). Open the url in the column right of your chat, or
  run the command in a terminal there, then post one line naming the one
  thing they need to do.
- `failed`: exit code 1; the error JSON on stderr says why.

Exit code 2 means the arguments were wrong: read `cmux setup --help`.

## 3. What to ask first

Default to doing it, with its undo. Ask the user first only when the change
reaches outside this Mac or cannot be undone: inviting people, creating a
paid Cloud machine, or giving a machine you have never seen access to this
one.

A message the user pasted from a task's `prompt` (in `cmux setup list`, or
docs/chief-setup-prompts.md) is their request for that task. The machine,
folder or browser it names counts as one they named, and the cloud-machine
prompt, which says they know it costs money, answers the ask for a paid
machine: run it without asking a second time. A word still in capitals
(HOST, FOLDER, BROWSER, EMAIL) is theirs to fill in: ask for it. Still
confirm an invite's address before you send it.

## Tasks

- Trust a folder: `cmux setup trust FOLDER` (default the current folder).
  Trust only a folder the user named or asked you to work in: trust lets
  agents run the folder's own hooks and configs without asking.
  `--level untrusted` records a refusal; `--level unknown` forgets the
  answer. A worktree shares its repository's answer: `via` names the folder
  that answer was made for, and forgetting it there makes every worktree of
  the repository ask again (`written` says which folder changed). It never
  edits Claude Code's or Codex's own files.
- Harness install and sign-in: `cmux setup harness [ID ...]` (default:
  every configured or found harness) says per harness whether it is
  installed, signed in and outdated. A signed-out one is `needs_user` with
  `cmux harness login ID` (a harness not configured yet: its own login
  command, such as `codex login`): run `user_action.command` in a terminal
  beside your chat and the user finishes the sign-in in the browser. A
  missing CLI is `needs_user` with the install docs as `url`. An outdated
  one names its `update` command; run it only when the user wants the
  update. Run `cmux setup harness ID` again after the user acts.
  `signed_in: null` means cmux cannot see the sign-in; it is still `ok`,
  and `auth_detail` says why when cmux knows. Setup never reads the login
  keychain itself and does not start a harness whose sign-in may be there
  (a Keychain item in its profile env, Codex keeping its login in the
  keychain, a Claude Code adapter).
  `cmux harness doctor ID --json` runs a real prompt turn when a harness
  that looks ready still fails.
- Add an ssh machine: `cmux setup machine SSH_TARGET [--name NAME]`. It is
  `ok` when the peer is already connected and current, updates a peer on an
  older build, and otherwise installs acpmux there and registers the peer;
  the undo of a new peer is `cmux acp host rm NAME`. It uses key-only ssh:
  when the machine refuses or does not answer, the result is `needs_user`
  with `user_action.command`, the ssh command to try. Hand the user that
  command; never ask for their password and never edit their ssh keys or
  `~/.ssh/config`. Without `--name` the peer is named after the host's first
  label; when that name already belongs to another peer, the result is
  `needs_user` with `user_action.kind` `name` and nothing changed: pick a
  new `--name`, or ask before passing the taken one (that moves the peer).
  Ask first before adding a machine the user did not name.
  `cmux setup status` lists every peer with `connected` and `outdated`, and
  the `fix` for each one that needs it.
- MCP outside cmux: `cmux setup mcp [claude|codex ...]` gives Claude Code
  and Codex started outside cmux (a terminal, another app) the cmux MCP
  server, through their own `mcp add`; chats cmux starts already have it.
  `needs_user` with `user_action.kind` `setting` means the person turns on
  `"mcp": {"enabled": true}` in the settings file the text names; hand them
  that line, do not edit the file. Kind `conflict` means their own server
  is named `cmux`: ask before removing it. `undo` is the shell line that
  puts each changed config back. With neither installed it is `ok`:
  nothing to wire, and the switch is not needed.
- Computer Use: `cmux setup computer-use` turns it on: cmux shows the user
  a sheet to allow it (tell them to click Allow), then each missing macOS
  grant comes back as `user_action` kind `grant`; run its `command` to
  open the System Settings pane and tell them which switch to turn on.
  Kind `wait` means it is starting: run the task again in a few seconds.
  Kind `declined` means it was not allowed (they said no, did not answer
  the sheet in time, or cmux had no window to show the sheet in): ask them
  before running it again.
- Cloud machine: ask the user first (it costs money every hour it runs and
  does not pause by itself), then run `cmux setup cloud-machine`. Signed
  out is kind `sign_in`: run its `command` and the user signs in in the
  browser. Otherwise cmux shows the user a card to allow the new machine
  (tell them to click it); the result names the `machine` and the `undo`
  that kills it and makes setup forget it. With `inferred: true` setup
  guessed which machine is its own: read `undo_note` and check with the
  user before running that undo. A machine they already have is `ok`, and
  a paused one has a `note` with the command that resumes it. Kind `wait`
  means cmux is still loading its machines or a machine is on its way: run
  the task again in a minute; it never makes a second machine. Kind
  `declined` means it was not allowed: ask before running it again. Kind
  `many_machines` means more than one new machine appeared and setup claims
  none: ask the user which is theirs. Kind `app` is cmux's own refusal, such as a plan with no room for another
  machine: tell the user what its text says. Run `cmux setup cloud-machine
  --forget` only after the machine was killed, or once the user says no
  machine is on its way (a `wait` on an empty list ends that way).
- Notifications: `cmux setup notifications` lets cmux show macOS
  notifications. The first time, macOS shows its prompt (tell them to click
  Allow). Kind `grant` means System Settings blocks them: either Allow
  Notifications is off, or it is on with the alert style None. Run its
  `command` to open cmux's page there and tell them what its `text` says
  to turn on. Kind `declined` means they said no: ask before running it
  again. Which notifications show are settings: `cmux settings set
  notifications.KEY VALUE`.
- Browser import: `cmux setup browser-import --browser BROWSER` (a name
  like Chrome or Arc; `chrome:Work` names one profile) imports its
  bookmarks into cmux; `ok` means that browser's bookmarks are already in
  (any profile of it, or the one named), and `undo` removes only the
  folders this run added. Kind `wait` means the import is still running:
  run it again in a few seconds. Without `--browser` the result is kind
  `choose`: ask the user which browser, or run its `command` to show them
  cmux's list. Cookies (their sign-ins) are theirs: ask the user first,
  then run it with `--cookies` and a `--reason` they will read
  (`--domain` keeps it to some sites); cmux shows them a panel to allow
  it, then macOS asks for the browser's Keychain password. It has no undo
  and running it again asks them again. Kind `declined` means it was not
  allowed (they said no, did not answer in time, or another request was
  already waiting): ask them before running it again. Kind `app` after
  `--cookies` may mean it ran: never run `--cookies` again without asking
  them. History and passwords only the user imports, from Import from
  Browser... in cmux.
