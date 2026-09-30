/// What happens to the local terminals when cmux quits. They run in the
/// local cmux-tui daemon, which outlives the app (cmux-tui-contract.md 1.5).
enum QuitSessionsChoice: String, Equatable, Sendable {
    /// Leave every local terminal and the daemon running.
    case keep
    /// End every local terminal and stop the local daemon
    /// (`shutdown-daemon end_terminals`).
    case end
}

/// Who asked to quit.
enum QuitOrigin: Equatable, Sendable {
    /// Cmd-Q, the Quit menu item or the Dock's Quit: may show the sheet.
    case interactive
    /// "Quit and Keep Sessions", "Quit and End Sessions", or `cmux app quit`
    /// with `--keep-sessions` / `--end-sessions`: runs as asked.
    case explicit(QuitSessionsChoice)
    /// `cmux app quit` (or `action.run quit`) with no flag: follows the
    /// setting and never waits on a sheet.
    case scripted
    /// Shut down, restart or log out: never asks, never ends terminals
    /// (the system ends them).
    case powerOff
}
