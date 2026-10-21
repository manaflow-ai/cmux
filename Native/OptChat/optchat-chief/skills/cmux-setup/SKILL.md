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
  puts each changed config back.
- Computer Use: `cmux setup computer-use` turns it on: cmux shows the user
  a sheet to allow it (tell them to click Allow), then each missing macOS
  grant comes back as `user_action` kind `grant`; run its `command` to
  open the System Settings pane and tell them which switch to turn on.
  Kind `declined` means they said no: do not ask again unless they bring
  it up.
