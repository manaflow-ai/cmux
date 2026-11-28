/// `newTerminal.opensWorkspace` in cmux.json: when enabled, a user initiated
/// New Terminal creates a workspace in the current space instead of a tab in
/// the focused workspace. Option-clicking a New Terminal control supplies a
/// one-shot override in either direction.
public nonisolated enum NewTerminalWorkspaceSetting {
}

nonisolated extension NewTerminalWorkspaceSetting {
    /// Resolves the persistent preference and the one-shot Option override.
    /// Keeping this rule pure makes the setting behavior easy to verify and
    /// keeps every New Terminal entrypoint on the same decision.
    public static func resolves(setting: Bool, toggled: Bool) -> Bool {
        setting != toggled
    }
}
