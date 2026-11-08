# Terminal sizing

`TerminalSizingEngine` decides the PTY grid of a terminal that several people and
devices view at once. The macOS app runs it as the host of local terminals; the
cmux-tui daemon runs the Rust twin (`cmux-tui-core/src/sizing_policy.rs`) as the
host of Cloud VM terminals. Viewers decode `TerminalSizingState` to draw bounds and
the size panel. The contract is `docs/shared-terminal-sizing.md`; both
implementations replay `schemas/terminal-sizing/fixtures.json`.
