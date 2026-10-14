# Background processes

Design for first-class background processes in acpmux. A background process
is a command a harness started in the background: a dev server, a watcher, a
long test run. Clients can list it, tail it and kill it. It runs past the
turn that started it and past the chat being closed, until it exits, someone
stops it, or the session's resource budget stops it.

Status 2026-10-14: design. What exists already:

- Claude's `background_task_update`: `running` when a shell goes to the
  background, then `completed`, `failed` or `stopped` when it ends.
- The idle reaper never ends a chat with a running shell.
- Each session's memory and CPU budget (`hub/budget.rs`).
- Lifted harness limits (`harness_limits.rs`).

The registry below builds on those. The NEXT GUI (op-next-launch) is built
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
  reason?       // why it stopped: "person", "agent", "budget_memory",
                // "harness_time_limit", "harness_exit"
  origin        // background | auto_backgrounded | user_backgrounded
  outputBytes
}
```

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
  writes. That file lives on the agent host's machine, so the host tails it,
  not the daemon. Claude Code does not need to stream the output.
- To stop a task, acpmux sends Claude Code's `stop_task` control request.

**Codex** (`codex app-server`, through the `cmux-codex-acp` bridge):

- A `commandExecution` item whose `processId` is still running when the item
  completes, which is unified exec handing back a session id.
- At session load, `thread/backgroundTerminals/list` (experimental) rebuilds
  the set.
- Output comes from `item/commandExecution/outputDelta`. The bridge spools it
  to a file per process in the session's state directory.
- To stop a process, acpmux calls `thread/backgroundTerminals/terminate`.
- Codex caps a session at 64 unified-exec processes; that cap is compiled
  in.

**Fallback for any harness:** when the harness is gone, the agent host
signals the process tree by the pid and start time it recorded
(`agent_host/tree.rs`).

## Wire

All requests are `_acpmux/*`. Each needs the session's own client, and the
remote relay keeps denying them until the relay analysis is done.

| Message | Params | Result |
| --- | --- | --- |
| `_acpmux/process/list` (request) | `{sessionId?}` (none: every session on this daemon) | `{processes: [Process]}` |
| `_acpmux/process/tail` (request) | `{processId, fromByte?, maxBytes?}` (default: the last 64 KiB) | `{data (base64), fromByte, nextByte, eof}` |
| `_acpmux/process/watch` (request) | `{processId}` | `{}`; then `_acpmux/process/output` notifications `{processId, data (base64), atByte}`, the same shape as v2's `terminal_output_chunk`, until `unwatch` or the process ends |
| `_acpmux/process/kill` (request) | `{processId, signal?: "term" \| "kill"}` | `{}`; the outcome arrives as a `process_update` |
| `_acpmux/process_update` (notification) | `{process: Process}` | |

**Migration:**

- `process_update` replaces the non-spec `background_task_update` session
  update. Both are sent for one release, then the old one is dropped. Its
  `running` state is what feeds the idle reaper today.
- Clients that declare JetBrains AIR's `asyncTasks` capability also get the
  lifecycle as `async_task_*`, and may stop a process with
  `_session/async_task/stop`.

## Lifetime

| Event | Behavior |
| --- | --- |
| Turn end | Keeps running. |
| Chat closed, no client attached | Keeps running: a running process blocks the idle reap. |
| Over the session's memory budget | The largest process under the harness is killed: `killed`, reason `budget_memory`. |
| Over the CPU budget | Reniced, not killed. |
| Harness time limit (Claude's `timeout`; acpmux lifts the ceiling to about 24.8 days) | `killed`, reason `harness_time_limit`. |
| Daemon restart | Keeps running (the agent host owns the harness); the list is rebuilt from the records and the harness's live set. |
| Harness or host exit, app update relaunch | `lost`, with the last output kept and Run again offered. A real reattach needs Claude Code's background sessions (`claude agents`, 2.1.196); evaluated separately. |
| Quit cmux | Open question (below). |

## Client contract for the GUI (op-next-launch)

- **Running row:** a background call's tool row becomes a live row showing
  the command, elapsed time, last output line, **Tail** and **Stop**. It
  replaces the end-only `BackgroundTaskNote`.
- **Composer chip:** "N running" opens the session's list.
- **Sidebar:** a chat row shows a running process even when no turn runs.
- **Slash commands:** `/ps` and `/stop` (the names Codex uses) map to list
  and kill.
- **SHOW LEO:** a new visual, so it is shown to Leo before merging.

## Tests (behavior, at the hub boundary)

- The fake Claude reports a background task. `process/list` shows it running,
  `process/tail` returns its output file's bytes, and `process/kill` sends
  `stop_task`, after which a `process_update` says `killed`.
- After a daemon restart, an adopted host's processes are listed again.
- A harness exit marks the session's running processes `lost`.
- The fake Codex app-server: a completed exec item with a live `processId`
  is listed, and `process/kill` calls `backgroundTerminals/terminate`.

## Open questions

- Should quitting cmux leave background processes running? Restore-everything
  argues for leaving them and marking `lost` only those that really died.
- Interactive stdin (Codex `write_stdin`; Claude Code has none): out of scope
  for this design; tail and kill cover servers and watchers.
- Whether `process/list` without a sessionId belongs to the person-only
  surface (`hub/person.rs`). Any person.rs change goes to the coordinator
  first.
