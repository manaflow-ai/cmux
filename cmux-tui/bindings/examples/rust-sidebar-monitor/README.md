# Rust sidebar monitor

This external package exercises the published `cmux-sdk` 1.0.0 and
`cmux-sidebar` 1.0.0 APIs. It keeps a bounded render queue, reopens the typed
attachment after a server gap, preserves unknown event kinds and raw payloads,
forwards Crossterm input, resizes and reloads the view, renders with Ratatui,
and distinguishes normal terminal ends from failures.

Run it against the socket selected by `CMUX_TUI_SOCKET`:

```bash
cargo run
```

Keys:

- `r` reloads the sidebar process.
- `q` or `Esc` cancels the attachment and exits.
- Other supported keyboard, mouse, paste, and focus events are forwarded.
- Terminal resize events resize the remote sidebar view.

Run the deterministic fake-server tests with the checked-in Rust toolchain:

```bash
cargo test --all-targets
cargo clippy --all-targets -- -D warnings
```
