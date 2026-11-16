/// What happens to the local terminals when cmux quits. They run in the
/// local cmux-tui daemon, which outlives the app (cmux-tui-contract.md 1.5).
public enum QuitSessionsChoice: String, Equatable, Sendable {
    /// Leave every local terminal and the daemon running.
    case keep
    /// End every local terminal and stop the local daemon
    /// (`shutdown-daemon end_terminals`); workspaces and splits stay and
    /// reopen with fresh shells.
    case endKeepLayout = "end-keep-layout"
    /// Also delete every local workspace first, so the next launch opens
    /// one new workspace.
    case endEverything = "end-everything"

    /// Whether the local terminals end.
    public var ends: Bool { self != .keep }
}

/// Who asked to quit.
public enum QuitOrigin: Equatable, Sendable {
    /// Cmd-Q, the Quit cmux menu item or the Dock's Quit: the one Quit, which
    /// quits the app and keeps every session running (CMUX-630, `QuitRules.decide`).
    case interactive
    /// "Quit and Keep Sessions", "Quit and End Sessions, Keep Layout",
    /// "Quit and End Everything" (command palette rows, not in the menu bar),
    /// or `cmux app quit` with `--keep-sessions`,
    /// `--end-sessions` or `--end-everything`: runs as asked.
    case explicit(QuitSessionsChoice)
    /// `cmux app quit` (or `action.run quit`) with no flag: quits the app and
    /// keeps every session, as Cmd-Q does,
    /// and never waits on a sheet.
    case scripted
    /// Shut down, restart or log out: never asks, never ends terminals
    /// (the system ends them).
    case powerOff
    /// SIGTERM (dev tooling, `kill`): "Quit, keep sessions", never an alert.
    case signal
}
