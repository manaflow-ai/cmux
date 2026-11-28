# Python development orchestrator

This Python 3.9+ example creates an isolated cmux development environment with
the public high-level SDK and the standard library. It validates the local
machine and session, creates an empty workspace, opens a typed
session event stream, creates a screen, two panes, an idle terminal tab, and
three exact-argv job terminals. Each job must match its output regex and then
exit successfully through the durable typed terminal-exit API.

Every create has a stable correlation key derived from `--run-id`. Each attempt
has a distinct idempotency key, carries the latest session revision, and records
replayed receipts. If a response is lost or the server reports an indeterminate
mutation, `session.creation.resolve()` returns the exact committed
`CreatedPath`, or proves that one bounded retry is safe. This applies to the
workspace and anonymous topology creates.

The workspace is closed on success or failure. `--keep-workspace` keeps it for
inspection. Passing `--workspace-id` asserts that the exact workspace belongs
to this run and may be closed.

Run the complete flow offline from the cmux worktree root:

```bash
PYTHONPATH=cmux-tui/bindings/python:cmux-tui/bindings/examples/python-dev-orchestrator \
  python3 cmux-tui/bindings/examples/python-dev-orchestrator/offline_demo.py
```

The fake implements the server side of `cmux.protocol/2`, including typed
snapshots and deltas, revision conflicts, replayed receipts, indeterminate
results, correlation lookup, terminal output waits, typed terminal exits,
stream cancellation, and cleanup. Production code does not encode protocol
frames, import `cmux.raw`, import private SDK modules, or send generic
operations.

Against a real cmux socket:

```bash
PYTHONPATH=cmux-tui/bindings/python \
  python3 cmux-tui/bindings/examples/python-dev-orchestrator/orchestrator.py \
  --socket "$CMUX_TUI_SOCKET" \
  --run-id "$CI_JOB_ID" \
  --cwd "$PWD" \
  --plan cmux-tui/bindings/examples/python-dev-orchestrator/plan.example.json
```

Without `--socket`, the SDK resolves `--socket-session`. The v2 endpoint
exposes one local machine and session; the example still retains their typed
IDs. Duplicate workspace names require `--workspace-id`.

Each plan contains exactly three jobs. `argv` is transmitted without shell
parsing. `ready_pattern` is a server-side regular expression that must appear
in the terminal viewport. A match is readiness evidence, while
`terminal.wait_exit` supplies the authoritative exit code. Set
`--request-timeout` longer than `--terminal-wait-timeout-ms`; the client
deadline also bounds both waits.

Run the deterministic integration tests:

```bash
cd cmux-tui/bindings/examples/python-dev-orchestrator
PYTHONPATH=../../python:. python3 -m unittest discover -s tests -v
```
