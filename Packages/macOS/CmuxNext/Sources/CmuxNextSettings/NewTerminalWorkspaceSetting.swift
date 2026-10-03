/// `newTerminal.opensWorkspace` in cmux.json: when enabled, a user initiated
/// New Terminal creates a workspace in the current space instead of a tab in
/// the focused workspace. Option-clicking a New Terminal control supplies a
/// one-shot override in either direction.
public nonisolated enum NewTerminalWorkspaceSetting {
    public static let configPath = ["newTerminal", "opensWorkspace"]
    public static let fallback = false

    /// Resolves the persistent preference and the one-shot Option override.
    /// Keeping this rule pure makes the setting behavior easy to verify and
    /// keeps every New Terminal entrypoint on the same decision.
    public static func resolves(setting: Bool, toggled: Bool) -> Bool {
        setting != toggled
    }

    /// A missing key is the default with no diagnostic; a bad value is the
    /// default plus a diagnostic.
    static func parse(_ root: JSONValue) -> (Bool, SettingsDiagnostic?) {
        guard let value = root.value(at: configPath) else { return (fallback, nil) }
        guard let enabled = value.boolValue else {
            return (fallback, SettingsDiagnostic(kind: .invalidValue, path: "newTerminal.opensWorkspace",
                                                   message: "expected true or false"))
        }
        return (enabled, nil)
    }
}
