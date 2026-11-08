# Terminal sharing (macOS)

The Mac side of shared terminal sizing (`docs/shared-terminal-sizing.md`).
`TerminalSharingStore` is the one owner of per-terminal size state and user
actions. `LocalTerminalSizingHost` runs `TerminalSizingEngine` for a local
terminal, where the Mac is the host. `CloudTerminalSizingRelay` is the Mac's
bookkeeping when it relays itself and paired phones to a cmux-tui host.
