/// `macScreen.*` in cmux.json: Mac Screen tabs' settings for every build
/// (the Development switches are `MacScreenDebugSettings`).
/// - `systemShortcuts` (off by default): while a Mac Screen tab has the
///   keyboard, system shortcuts (Cmd-Tab, Cmd-Space, Mission Control and
///   Spaces, screenshots, Cmd-Q/W/H/M) go to the other Mac instead of acting
///   on this one. Needs Accessibility for cmux.
public nonisolated struct MacScreenSettings: Sendable, Equatable {
    public var systemShortcuts = MacScreenSettings.systemShortcutsDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["macScreen"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("systemShortcuts") { settings.systemShortcuts = value }
        diagnostics = reader.diagnostics
        return settings
    }
}
