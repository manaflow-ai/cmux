# Python development orchestrator

This Python 3.9+ example creates an isolated cmux development environment with
the public high-level SDK and the standard library. It scans machines and
sessions, rejects duplicate names, creates an empty workspace, opens a typed
session event stream, creates a screen, two panes, an idle terminal tab, and
three exact-argv job terminals, then waits for each job's output regex.

Every mutation has a stable key derived from `--run-id`, carries the latest
session revision when supported, and records replayed receipts. An
indeterminate workspace create is reconciled by listing exact-name matches.
The code retries with a new key only when inspection proves that no matching
workspace exists. Anonymous topology creates are never retried blindly.

The workspace is closed on success or failure. `--keep-workspace` keeps it for
inspection. Passing `--workspace-id` asserts that the exact workspace belongs
to this run and may be closed.

Run the complete flow offline from the cmux worktree root:

```bash
PYTHONPATH=cmux-tui/bindings/python:cmux-tui/bindings/examples/python-dev-orchestrator \
  python3 cmux-tui/bindings/examples/python-dev-orchestrator/offline_demo.py
```

The fake implements the server side of `cmux.protocol/1`, including typed
snapshots and deltas, revision conflicts, replayed receipts, indeterminate
results, terminal output waits, stream cancellation, and cleanup. Production
code does not encode protocol frames, import `cmux.raw`, import private SDK
modules, or send generic operations.

Against a real cmux socket:

```bash
PYTHONPATH=cmux-tui/bindings/python \
  python3 cmux-tui/bindings/examples/python-dev-orchestrator/orchestrator.py \
  --socket "$CMUX_TUI_SOCKET" \
  --run-id "$CI_JOB_ID" \
  --cwd "$PWD" \
  --plan cmux-tui/bindings/examples/python-dev-orchestrator/plan.example.json
```

Without `--socket`, the SDK resolves `--socket-session`. If more than one
machine has the requested `--session-name`, rerun with the candidate
`--session-id` and `--machine-id` printed in the error. Duplicate workspace
names similarly require `--workspace-id`.

Each plan contains exactly three jobs. `argv` is transmitted without shell
parsing. `ready_pattern` is a server-side regular expression that must appear
in the terminal viewport. Set `--request-timeout` longer than
`--terminal-wait-timeout-ms`; the example validates this because the SDK's
request deadline also bounds `terminal.wait`.

Run the deterministic integration tests:

```bash
cd cmux-tui/bindings/examples/python-dev-orchestrator
PYTHONPATH=../../python:. python3 -m unittest discover -s tests -v
```
