# Rust agent dashboard

This standalone Rust 1.88+ consumer selects the current session, refreshes
typed workspace handles, and queries agents with typed `AgentState` filters.
It renders opaque resource IDs without parsing protocol documents and can send
one warning notification for each transition into the blocked filter.
Transport failures trigger a fresh `Client` and complete snapshot refresh.

From the cmux repository root:

```bash
cargo run --manifest-path cmux-tui/bindings/examples/rust-agent-dashboard/Cargo.toml -- --session main
```

Type `q` then Enter to stop. Use `--socket /path/to/session.sock`,
`--notify-blocked`, `--poll-ms 250`, or `--once` as needed.

Tests use a deterministic Unix-socket resource-protocol server and assert that
the consumer sends only named high-level operations.
