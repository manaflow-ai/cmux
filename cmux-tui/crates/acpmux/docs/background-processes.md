# Background processes

Design for first-class background processes in acpmux. A background process
is a command a harness started in the background: a dev server, a watcher, a
long test run. Clients can list it, tail it and kill it. It runs past the
turn that started it and past the chat being closed, until it exits, someone
stops it, or the session's resource budget stops it.

Status 2026-10-14: partly built. What exists:

- Lifted harness limits (`harness_limits.rs`, #20585).
- Claude's `background_task_update`: `running` when a shell goes to the
  background, then `completed`, `failed` or `stopped` when it ends (#20585).
- The registry for Claude Code's shells (`hub/processes.rs`,
  `server/processes.rs`, #20724): `process/list`, `process/kill` and
  `process_update`. The idle reaper asks it whether anything runs.
- `process/tail` (cx-d2vha): reads the `output_file` Claude Code names for
  the shell, which the record keeps (`outputFile`); `outputBytes` is the
  file's length when listed. Claude Code only for now: a Codex process is
  refused.
- Codex's background terminals in the same registry (cx-gmkk5): the bridge
  (`codex_app_server/background.rs`) reports them as
  `background_task_update`, and `process/kill` calls
  `thread/backgroundTerminals/terminate`.
- `process/background` (Ctrl-B): Claude Code's `background_tasks` control
  request moves a chat's foreground work to the background; the shells it
  moved are listed with origin `user_backgrounded`.

Not built yet: `process/watch`, Codex's output and its
`thread/backgroundTerminals/list` at session load, and the per-session
resource valve. The valve was dropped from #20585 because it
read `ps` and `/proc`, and cmux-next never scans processes
(`plans/cmux-next/pty-holder.md` §4). It comes back without scanning in
cx-v9s8g. The NEXT GUI (op-next-launch) is built
on the wire contract in this document. The decision to stay on ACP and extend
it rather than fork is recorded in cmuxterm-hq#2014.

## Why acpmux owns it

ACP has no process entity:

- v1's client-side `terminal/*` methods are about to be removed (RFD #1346).
- v2's agent-owned `terminal_update` and `terminal_output_chunk` only display
  output (RFD #1679).
- Nothing in the spec, in an RFD or in an open PR lists processes, tails them
  or kills them. agentclientprotocol issue #1847 asks only for a status on tool
  calls that outlive their turn.
- The only working convention is JetBrains AIR's `async_task_*` updates and
  `_session/async_task/stop`, which the adapters send only to AIR clients.

So the registry is an acpmux extension: `_acpmux/*` methods and
notifications, as ACP's extensibility rules allow. Once it works for us, we
offer it upstream as an RFD.

## Model

The daemon keeps one record per process, with the session's record, so a
daemon restart lists them again:

```
Process {
  id            // acpmux's own id: "<sessionId>/<harness task id>"
  sessionId
  toolCallId    // the Bash / exec call that started it
  harness       // "claude" | "codex"
  command, cwd
  startedAt, endedAt?
  state         // running | exited | failed | killed | lost
  exitCode?, signal?
  reason?       // why it stopped: "person", "agent", "harness_exit";
                // later "budget_memory", "harness_time_limit"
  detail?       // the harness's own words on its end (Claude's summary)
  origin        // background | auto_backgrounded | user_backgrounded
  outputBytes   // the output file's length when listed; null with no file
  outputFile?   // the file the harness writes its output to
}
```

As built (#20724), `subagentSessionId` names the subagent whose call started
it, and a task id a later harness reuses gets `-2`, `-3`. Each change is
logged once as a mux `process_update` record, which is how a daemon rebuilds
the table.

`lost` means the process ended without anyone seeing how, for example when the
harness itself exited. Its last output is kept and its command is shown with
**Run again**.

## Where the records come from

**Claude Code** (stream-json):

- `task_started` / `task_updated` / `task_notification` for `task_type`
  `local_bash` and `local_monitor`. `local_agent` stays in the subagent model.
- `background_tasks_changed` carries the full live set, so a missed event is
  repaired on the next one.
- Output comes from tailing the `tasks/<id>.output` file Claude Code already
  writes, named by `output_file` on its task events. That file lives on the
  agent host's machine; the host runs on the daemon's machine, so the daemon
  reads it (peers are refused). Claude Code does not need to stream the
  output.
- To stop a task, acpmux sends Claude Code's `stop_task` control request.
- To move running work to the background (Ctrl-B), acpmux sends Claude
  Code's `background_tasks` control request (2.1.305): with `tool_use_id`
  only the task that tool call started, without it every foreground task,
  as Claude Code's own Ctrl-B does. Its answer carries `backgrounded`
  (Claude Code's SDK reads a missing one as true). The moved shells then
  come as task events like any other, and the translator gives the ones
  that were in the foreground at the request origin `user_backgrounded`.
  The hub waits 10 s for the answer and passes that wait to the translator
  (`timeoutMs`). The marks go again when the answer says nothing moved, when
  that wait ends unanswered, or when the turn ends first, so a shell Claude
  Code moves later on its own stays `auto_backgrounded`. A shell that already
  moved, or that another request moved or still waits on, keeps its mark: of
  two Ctrl-Bs close together, the second's `backgrounded: false` leaves the
  first's shell the person's.

**Codex** (`codex app-server`, through the `cmux-codex-acp` bridge):

- A `commandExecution` item whose `processId` is still running when the item
  completes, which is unified exec handing back a session id. As built, the
  bridge (`codex_app_server/background.rs`) watches the raw app-server lines
  beside the translator, which drops `processId`. An exec item with a
  `processId` is a background terminal when its `item/completed` still says
  `inProgress`, or when its turn completes (status `completed`) before the
  item does; a turn that was interrupted or failed hands nothing to the
  background. It is
  reported as a `background_task_update` (`toolCallId` the item id, `taskId`
  the `processId`, `origin` `background`), so the hub's registry folds it as
  it folds Claude's. A later `item/completed` ends it (`exited` or `failed`,
  with its `exitCode`).
- At session load, `thread/backgroundTerminals/list` (experimental) rebuilds
  the set. Not built: the hub rebuilds from the session log, and a
  terminal left running at a daemon restart stays `running` until the
  bridge sees its end or the harness exits.
- Output comes from `item/commandExecution/outputDelta`. The bridge spools it
  to a file per process in the session's state directory.
- To stop a process, acpmux calls `thread/backgroundTerminals/terminate`
  `{threadId, processId}` (built), on the thread that runs it: a subagent's
  own thread (its `subagentSessionId`), else the chat's. The bridge sends it
  under its own request ids. `terminated: true` ends it `killed` by the
  person, and so does an item end that arrives before the answer. `false`
  (Codex no longer had it) refuses the kill with that error and ends the
  process `exited` with that detail.
- `process/tail` is Claude Code only for now (#20917): on a Codex process
  it is refused with invalid params "tail is Claude Code only for now".
- Codex caps a session at 64 unified-exec processes; that cap is compiled
  in.

**Fallback for any harness:** when the harness is gone, its holder signals
the harness's process group; nothing walks the process tree (cx-t2sqm.3
replaces `agent_host/tree.rs`'s `ps` walk).

## Wire

All requests are `_acpmux/*`. Like `_acpmux/kill`, they are local: the unix
socket and the local app may call them (the socket is the same-user trust
boundary), and Web and Peer connections are refused before routing, so a
process's command line and its kill never leave the machine.

| Message | Params | Result |
| --- | --- | --- |
| `_acpmux/process/list` (request, built) | `{sessionId?, limit?, cursor?}`; without `limit`, existing full list. With `limit`, `sessionId` required and `cursor` is the previous page's `nextCursor`. Requested limit is capped to 1,000. | Unpaged: `{processes: [Process]}`. Paged: `{processes: [Process], nextCursor: string|null}`. Pages are additionally cut to fit the 31 MiB RPC frame; a single oversized record gives an explicit `omitted` stub preserving process identity and state. |
| `_acpmux/process/tail` (request, built) | `{processId, fromByte?, maxBytes?}` (default: the last 64 KiB; at most 1 MiB) | `{data (base64), fromByte, nextByte, eof}`; `eof`: the process ended and `nextByte` is the file's end; a missing file is empty data |
| `_acpmux/process/watch` (request) | `{processId}` | `{}`; then `_acpmux/process/output` notifications `{processId, data (base64), atByte}`, the same shape as v2's `terminal_output_chunk`, until `unwatch` or the process ends |
| `_acpmux/process/kill` (request, built) | `{processId, sessionId?, signal?: "term" \| "kill"}`; a named `sessionId` must be the process's chat (the agent pane names it, and its host allows only a chat in the pane's scope) | `{}`; the outcome arrives as a `process_update` |
| `_acpmux/process/background` (request, built) | `{sessionId, toolCallId?}` (none: every foreground task) | `{backgrounded: bool}`; false when no turn runs or nothing ran in the foreground. Claude Code (a claude-stdio harness, whatever its name) only: any other chat is refused with invalid params (Codex moves long commands to the background itself). Every session summary says which chats it takes (`backgroundsWork`). Claude Code's error is the request's error. What moved arrives as `process_update`s, origin `user_backgrounded` |
| `_acpmux/process_update` (notification, built) | `{process: Process}` | |

**Migration:**

- `process_update` replaces the non-spec `background_task_update` session
  update. Both are sent now (#20724); the old one is dropped once the GUI
  reads `process_update`. A shell left running at Claude's exit keeps its
  update unchanged and adds `_meta.acpmux.endedBy: "harness_exit"`.
- Clients that declare JetBrains AIR's `asyncTasks` capability also get the
  lifecycle as `async_task_*`, and may stop a process with
  `_session/async_task/stop`.

## Lifetime

| Event | Behavior |
| --- | --- |
| Turn end | Keeps running. |
| Chat closed, no client attached | Keeps running: a running process blocks the idle reap. |
| Over the session's memory budget (cx-v9s8g) | Enforced by the kernel, not by acpmux measuring: on Linux the session's cgroup scope (`MemoryMax`); `killed`, reason `budget_memory`. |
| Over the CPU budget (cx-v9s8g) | Lower priority, not killed: the cgroup's `CPUWeight` on Linux, `setpriority(PRIO_PGRP)` on macOS. |
| Start (macOS) | The harness starts at normal CPU class: a start has a deadline, and at background class a busy disk can hold it past that deadline (2026-10-30: a harness at background class used under 1 s of CPU in 90 s of trust-settings reads). Once the session's start is over (`initialize` and `session/new` or `session/load` answered), the daemon puts the running harness in background CPU class (`setpriority(PRIO_DARWIN_PROCESS, pid, PRIO_DARWIN_BG)`, `cpu_class.rs`), so every process it starts after that inherits it and cmux's GUI and renderers go first. A process the harness started during its start keeps normal class, because acpmux lists no processes: an MCP server, and the real agent of a harness that is only a launcher (a script or adapter that starts the agent as a child), whose turns then run at normal class. The daemon also clears a background class that another process set, right after the spawn. Disk I/O stays at the daemon's and host's utility tier. A start that still fails at background class is retried once, and a start that misses its deadline names its agent process's pid, class, run time, CPU time and running threads. `normal` opts out of the lowering: a profile's env `ACPMUX_SESSION_CPU_CLASS`, the daemon's env, or config `session.cpuClass`. |
| Harness time limit (Claude's `timeout`; acpmux lifts the ceiling to about 24.8 days) | `killed`, reason `harness_time_limit`. |
| Daemon restart | Keeps running (the agent host owns the harness); the list is rebuilt from the `process_update` records. A process still `running` there stays so until its harness reports its end. |
| Harness or host exit, app update relaunch | `lost` (built), with the last output kept and Run again offered. A real reattach needs Claude Code's background sessions (`claude agents`, 2.1.196); evaluated separately. |
| Quit cmux | Open question (below). |

## Client contract for the GUI (op-next-launch)

- **Running row:** a background call's tool row becomes a live row showing
  the command, elapsed time, last output line, **Tail** and **Stop**. It
  replaces the end-only `BackgroundTaskNote`.
- **Composer chip:** "N running" opens the session's list.
- **Sidebar:** a chat row shows a running process even when no turn runs.
- **Slash commands:** `/ps` and `/stop` (the names Codex uses) map to list
  and kill.
- **Ctrl-B:** while a Claude Code turn runs, Ctrl-B in the chat sends
  `process/background {sessionId}`, as Ctrl-B does in Claude Code itself; a
  running tool row's own button may name its `toolCallId`. On
  `backgrounded: true` the turn goes on and the moved work shows up as
  running rows (origin `user_backgrounded`); `false` means nothing ran in
  the foreground. Offer it only where the chat's session summary says
  `backgroundsWork` (a Claude Code chat whatever its harness is named, the
  `cmux` model router's profile too), never by the harness's name; other
  harnesses are refused. The CLI is `acpmux process background SESSION [--tool-call ID]`.
- **SHOW LEO:** a new visual, so it is shown to Leo before merging.

## Tests (behavior, at the hub boundary)

- Built (`tests/hub_integration/processes.rs`): the fake Claude reports a
  background task, a subagent's included; `process/list` shows it running;
  `process/kill` sends `stop_task`, after which a `process_update` says
  `killed` by the person; a harness exit marks running processes `lost`; Web
  and Peer connections are refused; `process/tail` returns the output file's
  bytes, pages with `fromByte`/`maxBytes`, says `eof` after the shell ends,
  reads a missing file as empty, and refuses unknown ids;
  `process/background` sends `background_tasks` with and without
  `tool_use_id`, answers Claude Code's `backgrounded`, lists the moved shell
  `user_backgrounded`, answers false with no turn running without asking,
  turns Claude Code's refusal into an error, leaves no mark when Claude Code
  never answers or the turn ends first, keeps the first of two requests'
  shell the person's when the second answers false, and refuses a chat of another
  agent (Codex too, in `codex_processes.rs`) and Web and Peer connections.
  A chat's summary says `backgroundsWork` by its harness's kind: the
  `cmux` router profile (claude-stdio) yes, and Ctrl-B moves its work; an
  ACP agent named `claude-acp` no, and it is refused.
- To build: after a daemon restart an adopted host's processes are listed
  again.
- Built (`tests/hub_integration/codex_processes.rs`, the fake Codex
  app-server): an exec item left open at its turn's end, or completed while
  its process runs, is listed `running` with harness `codex`; one that exits
  keeps its exit code; `process/kill` calls
  `thread/backgroundTerminals/terminate` and the process ends `killed` by
  the person, once, also when Codex ends the item before answering; a
  subagent's terminal is terminated on its own thread; a terminal Codex no
  longer has is refused and ended; an interrupted turn lists nothing; the
  app-server's exit marks it `lost`; `process/tail` on one is refused.

## Open questions

- Should quitting cmux leave background processes running? Restore-everything
  argues for leaving them and marking `lost` only those that really died.
- Interactive stdin (Codex `write_stdin`; Claude Code has none): out of scope
  for this design; tail and kill cover servers and watchers.
- Decided (coordinator, 2026-10-14): `process/list` stays symmetric with
  `_acpmux/kill`, with no `hub/person.rs` change. A person-only list across
  all chats is bead cx-r6tvw.
