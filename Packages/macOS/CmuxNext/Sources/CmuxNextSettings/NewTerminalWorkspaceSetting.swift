/// `newTerminal.opensWorkspace` in cmux.json: when enabled, a click on a New
/// Terminal control creates a workspace in the current space instead of a tab
/// in the focused workspace. Option-clicking a New Terminal control supplies a
/// one-shot override in either direction. New Terminal Tab's key (Ctrl-`)
/// always opens a tab in the focused workspace (``opensWorkspace(setting:toggled:byPerson:byKey:)``).
public nonisolated enum NewTerminalWorkspaceSetting {
}

nonisolated extension NewTerminalWorkspaceSetting {
    public static let configPath = ["newTerminal", "opensWorkspace"]
    public static let fallback = false

    /// Resolves the persistent preference and the one-shot Option override.
    /// Keeping this rule pure makes the setting behavior easy to verify and
    /// keeps every New Terminal entrypoint on the same decision.
    public static func resolves(setting: Bool, toggled: Bool) -> Bool {
        setting != toggled
    }

    /// Whether a New Terminal run makes a workspace instead of a tab in the focused one: a
    /// person's click on a New Terminal control (`byPerson`, not `byKey`) that
    /// ``resolves(setting:toggled:)`` says should. A key press (New Terminal Tab's Ctrl-`) always
    /// opens the terminal in the focused workspace: the setting is about the controls, and a key
    /// has no Option to reverse it (Ctrl-Option-` is another chord). Before, Ctrl-` with the
    /// setting on made a whole new workspace (https://github.com/manaflow-ai/cmux/issues/34431).
    public static func opensWorkspace(setting: Bool, toggled: Bool, byPerson: Bool, byKey: Bool) -> Bool {
        byPerson && !byKey && resolves(setting: setting, toggled: toggled)
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
