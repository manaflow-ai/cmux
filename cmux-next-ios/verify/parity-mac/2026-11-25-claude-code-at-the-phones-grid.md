# Claude Code in a terminal, drawn at the phone's own grid (fit to phone by default; the Mac never resizes)

- Section: Terminal
- Mac sends: daemon `agent-cli-phone-grid-v1`: on `attach-surface` with `view_cols`/`view_rows`, a Claude Code terminal's frames (`agent-cli-lean`) are `cmux_agent_cli_render::claude::render` at the phone's grid, from the session's transcript and the facts read off the Mac's screen (`server/agent_cli_phone.rs`); rows above the screen go into the phone's own scrollback
- Phone: every terminal pane running Claude Code, by default (no setting); shells, Codex, opencode and full-screen programs keep the byte stream and the phone's reflow
- State: partial
- Notes: Leo, 2026-11-25: "do everything at parity on the phone"; "you obviously fit to phone by default". Parity against real Claude Code 2.1.332 screens at 50x34, 54x38 and 59x42, CI floors in `cmux-tui/crates/cmux-agent-cli-render/tests/fixtures/phone/parity-floor.json` (cmux#56808 and this PR). Limits: a tap in the pane is not mapped to the Mac's cell; a phone rotation keeps the attach's grid until the next attach.
