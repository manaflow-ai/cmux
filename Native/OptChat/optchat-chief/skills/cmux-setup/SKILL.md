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
  answer. It never edits Claude Code's or Codex's own files.
- Harness install and sign-in: `cmux harness doctor ID --json` names the
  failing step and its fix; `cmux harness login ID` starts the sign-in.
- Add an ssh machine: `cmux acp host setup SSH_TARGET --json`, then
  `cmux acp host ls --json` to see it connected.
