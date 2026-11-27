# Per-call tool placement: each call runs where its data lives

An agent's loop can run on one machine (a Cloud VM) while the person watches and steers the
same chat from another (their Mac, their phone). This page says where each tool call of such a
session runs, what carries it, who allows it, and what is not built yet.

## The rule

A session has one home: the machine its harness process and its checkout are on. A tool call
runs on the home machine unless the thing it acts on exists only on another machine.

| The call acts on | Runs on | With |
| --- | --- | --- |
| The session's checkout: read, edit, search, git, build, test | Home | The harness's own tools |
| The network: fetch, search, an API | Home | The harness's own tools |
| A screen, window or app of the person's machine | That machine | Computer Use with `machine` |
| A file that exists only on the person's machine (a download, a log, an app's settings) | That machine | `machine_read`, `machine_edit` |
| A program only that machine has (open an app, a tool installed there, a device attached to it) | That machine | `machine_exec` |

The agent decides per call, by naming a machine or not. Nothing guesses from a path: the same
path can exist on both machines and mean different files. The tools' descriptions carry the
rule ("use it for what lives on that machine; build and test on this machine"), so a session
needs no extra prompt.

## No file sync

The checkout on the home machine is the only copy the session works on. Nothing mirrors it to
the person's machine, in either direction:

- A mirrored checkout costs the person's machine what the move was meant to save. Every write
  the agent or its build makes becomes a file event, an index update and a watcher wake-up
  there.
- Two writable copies need a merge rule. One copy and per-call access need none.

When the person wants the work on their own disk, it travels as git does: the session pushes
a branch, the person fetches it. One file crosses with one `machine_read` or `machine_edit`
call (16 MB a request).

## What is kept between calls

- **The way.** The first call to a machine opens one hub carrier circuit to it; the circuit
  stays open and each later call is one stream on it. No ssh, no peer set up by hand, and no
  process started per call on either side: the answering side is one task in the daemon. The
  only process a call starts is the command a `machine_exec` names.
- **Not the grant.** The far machine reads its own grant and consent again for every call,
  before and after the policy's decision. A grant taken back stops the next call.
- **Not file contents.** A read answers the file's text and its sha256. An edit names the
  sha256 it was made against (`expect_sha256`) and is refused when the file has changed since,
  so the agent's own context is the only cache and it cannot overwrite what it has not seen.

## Who allows a call

Three decisions, each on the machine that owns it:

1. **The agent's permission prompt**, on the home machine, shown in the person's chat on
   whichever device they have open. `machine_read`, `machine_edit` and `machine_exec` are three
   tools so that prompt and its rules tell a read from an edit from a command.
2. **The grant**, on the far machine: "control for my other machines signed in to this
   account". Signing in never gives it. Until the person gives it there, every call is refused
   with that reason and the far machine's app shows its one ask.
3. **The policy**, on the far machine (`src/machine_files.rs`, the hand's rules for a
   person's machine): paths inside the home folder or the temp folders only; never cmux's own
   files; never the destructive commands and paths refused at every level. Computer Use calls
   go through that machine's Computer Use settings, deny list and approvals instead.

A call that touches credentials, startup files or a folder holding them is the far machine
owner's to answer there. Nothing can ask them from another machine yet, so it is refused
(`policy.needs_owner`) and never run. For a command this is a filter on what its command line
names, not a sandbox: a command that builds such a path at run time is not caught. A command with
no `cwd` runs in that machine's work folder; where none is set that is the home folder, which
holds credentials, so the command is refused the same way. Give a `cwd` inside the home folder.

Only an agent on the home machine's own socket may send a call
(`src/server/machine_files_relay.rs`, `src/server/computer_use_relay.rs`): a peer, a paired
device or the web is refused, so nothing reaches a third machine through this one.

## Not built

- Asking the far machine's owner there for a `policy.needs_owner` call.
- Streaming a long command's output: `machine_exec` answers once, at the end (ten minutes at
  most, 256 KB a stream).
- A pty on the far machine. Use a terminal pane there.
