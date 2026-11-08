# Python agent watchdog

This zero-dependency Python 3.9+ process follows one typed session event stream
and periodically reads the session's resource snapshot. It warns when an agent
is `blocked`, or when a `working` agent has not changed within the configured
threshold. Each warning names the typed terminal and its workspace ancestry,
then includes the visible screen or a terminal-history fallback. A lost Unix
socket triggers bounded exponential reconnects and restores the event stream.
Screen reads use `TerminalScreenResult.text`. The fallback flattens typed
`TerminalHistoryResult.rows` while preserving row boundaries.

From the cmux checkout:

```bash
PYTHONPATH=cmux-tui/bindings/python python3 cmux-tui/bindings/examples/python-agent-watchdog/watchdog.py --session main
```

Use `--socket /path/to/session.sock` to bypass socket discovery,
`--stalled-after 120` to change the stale threshold, and Ctrl-C for clean
shutdown.

The tests use a deterministic resource-protocol fake server to cover unknown
future events, reconnection, resubscription, notification capture, and stall
timing. A separate integration case forces an empty screen and verifies the
typed history fallback.
