# Zig session supervisor

This Zig 0.15.2 consumer uses only the public `cmux_tui` resource API and the
Zig standard library. It discovers one machine and session by exact name,
rejects ambiguous user-named workspaces, creates a missing workspace, runs an
exact argv command, waits for its durable terminal exit, reads one bounded
session event, and cancels the event stream.

Creation calls use a stable correlation key across retries. After an
indeterminate response, the supervisor asks `session.creation.resolve` whether
the effect committed. A `created` result supplies the exact resource path. A
`not_applied` result permits one retry with the recovery-directed idempotency
key. Pending and indeterminate resolutions stop without guessing.

Build and test both supported optimization modes from the repository root:

```sh
cd cmux-tui/bindings/examples/zig-session-supervisor
zig version
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
zig build -Doptimize=Debug
zig build -Doptimize=ReleaseSafe
```

`zig version` should print `0.15.2`. The deterministic Unix socket tests cover
not-applied workspace recovery, committed run recovery, exact argv encoding,
typed exit status, event cancellation, inherited stream timeouts, duplicate
workspace names, pending-to-exited polling, opaque IDs, and allocator cleanup.

Run against an explicit resource socket:

```sh
zig build run -- \
  /path/to/cmux.sock \
  local \
  main \
  ci \
  deploy-2026-07-29 \
  -- printf 'hello world\n'
```

The run key is durable application state. Reusing it preserves the workspace
and command correlation keys after a response is lost. Use a new run key for a
new logical command.
