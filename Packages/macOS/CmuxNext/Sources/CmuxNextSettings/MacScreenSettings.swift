/// `macScreen.*` in cmux.json: Mac Screen tabs' settings for every build
/// (the Development switches are `MacScreenDebugSettings`).
/// - `systemShortcuts` (off by default): while a Mac Screen tab has the
///   keyboard, system shortcuts (Cmd-Tab, Cmd-Space, Mission Control and
///   Spaces, screenshots, Cmd-Q/W/H/M) go to the other Mac instead of acting
///   on this one. Needs Accessibility for cmux.
/// - `onlyPersonStartsViewing` (off by default): a Screen Sharing tab an agent
///   or the CLI opens waits at the Connect card for the person's click. Off,
///   one on the person's own device starts viewing at once
///   (`MacScreenPages.agentMayStartViewing`).
public nonisolated struct MacScreenSettings: Sendable, Equatable {
    public var systemShortcuts = MacScreenSettings.systemShortcutsDefault
    public var onlyPersonStartsViewing = MacScreenSettings.onlyPersonStartsViewingDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["macScreen"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("systemShortcuts") { settings.systemShortcuts = value }
        if let value = reader.bool("onlyPersonStartsViewing") { settings.onlyPersonStartsViewing = value }
        diagnostics = reader.diagnostics
        return settings
    }
}
