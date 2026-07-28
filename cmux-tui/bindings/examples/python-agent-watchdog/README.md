# Python agent watchdog

This zero-dependency Python 3.9+ process connects to one cmux TUI session,
identifies the server, lists agents and workspaces, and maintains both coarse
and delta event subscriptions. It warns when an agent reports `blocked`, or
when a `working` record has not changed within the configured threshold. Each
warning includes the current screen or a scrollback fallback. A lost Unix
socket triggers bounded exponential reconnects and restores both subscriptions.

From the cmuxterm-hq checkout:

```bash
PYTHONPATH=worktrees/feat-tui-sdk-stack/cmux-tui/bindings/python python3 worktrees/feat-tui-sdk-stack/cmux-tui/bindings/examples/python-agent-watchdog/watchdog.py --session main
```

Use `--socket /path/to/session.sock` to bypass session discovery,
`--stalled-after 120` to change the stale threshold, and Ctrl-C for clean
shutdown.

The `tests` directory contains deterministic fake-server coverage for future
events, reconnection, resubscription, notification capture, and stall timing.
