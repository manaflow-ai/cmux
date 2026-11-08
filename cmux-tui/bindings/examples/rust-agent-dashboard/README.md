# Rust agent dashboard

This standalone Rust 1.88+ consumer selects the current session and refreshes
one exact resource snapshot containing typed workspaces, agents, and terminal
IDs. It renders opaque resource IDs and can send one warning notification to
the exact terminal for each transition into the blocked state. Transport
failures trigger a fresh `Client` and complete snapshot refresh.

The library also exposes `run_command_check`. It supplies stable correlation
and idempotency keys to `workspace.run`, resolves the created terminal after an
uncertain transport result, performs a bounded `terminal.wait_exit`, and reads
the terminal's durable lifecycle and exit outcome.

From the cmux repository root:

```bash
cargo run --manifest-path cmux-tui/bindings/examples/rust-agent-dashboard/Cargo.toml -- --session main
```

Type `q` then Enter to stop. Use `--socket /path/to/session.sock`,
`--notify-blocked`, `--poll-ms 250`, or `--once` as needed.

Tests use a deterministic Unix-socket resource server. They prove typed
snapshot refresh, terminal-targeted notifications, reconnect, correlated
creation recovery, and exact exit code 17 without low-level APIs.
