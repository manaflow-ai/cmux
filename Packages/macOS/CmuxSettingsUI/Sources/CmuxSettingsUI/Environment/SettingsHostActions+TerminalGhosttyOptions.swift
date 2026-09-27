import CmuxFoundation

/// Defaults for previews, tests, and hosts without a Ghostty config.
public extension SettingsHostActions {
    /// Ghostty's defaults.
    func terminalGhosttyOptions() async -> GhosttyTerminalOptions { .defaults }

    /// Accepts the change without persisting it.
    func applyTerminalGhosttyOption(_ change: GhosttyTerminalOptionChange) async -> Bool { true }
}
