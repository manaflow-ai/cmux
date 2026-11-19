/// `macScreen.*` in cmux.json: Mac Screen tabs' settings for every build
/// (the Development switches are `MacScreenDebugSettings`).
/// - `systemShortcuts` (off by default): while a Mac Screen tab has the
///   keyboard, system shortcuts (Cmd-Tab, Cmd-Space, Mission Control and
///   Spaces, screenshots, Cmd-Q/W/H/M) go to the other Mac instead of acting
///   on this one. Needs Accessibility for cmux.
/// - `defaultQuality` (Auto by default): the quality a new Mac Screen tab
///   starts with; the toolbar still changes the session's live.
/// - `defaultAccess` (Full Control by default): what a new tab's Connect
///   card asks for first (its Return button).
public nonisolated struct MacScreenSettings: Sendable, Equatable {
    public var systemShortcuts = MacScreenSettings.systemShortcutsDefault
    public var defaultQuality = MacScreenSettings.defaultQualityDefault
    public var defaultAccess = MacScreenSettings.defaultAccessDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["macScreen"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("systemShortcuts") { settings.systemShortcuts = value }
        if let value = reader.choice("defaultQuality", MacScreenDefaultQuality.self) { settings.defaultQuality = value }
        if let value = reader.choice("defaultAccess", MacScreenDefaultAccess.self) { settings.defaultAccess = value }
        diagnostics = reader.diagnostics
        return settings
    }
}
