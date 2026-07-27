# Rust agent dashboard

This standalone consumer connects to one cmux-tui session, registers a delta
subscription before fetching its first snapshots, and renders workspace and
agent state from typed SDK models. Topology updates arrive as events. Protocol
10 has no agent-change event, so the dashboard refreshes `list-agents` once per
second. Blocked and done agents are sorted into view first.

From the cmux repository root:

```bash
cargo run --manifest-path cmux-tui/bindings/examples/rust-agent-dashboard/Cargo.toml -- --session main
```

Type `q` then Enter to close the subscription and command connection cleanly.
Use `--socket /path/to/session.sock` for an explicit socket,
`--notify-blocked` to create a typed warning notification on each transition to
blocked, `--poll-ms 250` to change the agent refresh interval, or `--once` for
one snapshot. Connection and subscription failures are printed and retried
without reusing stale snapshots.

Verify the independent consumer with:

```bash
cargo test --manifest-path cmux-tui/bindings/examples/rust-agent-dashboard/Cargo.toml
```
