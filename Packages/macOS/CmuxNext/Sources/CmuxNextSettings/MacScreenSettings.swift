/// `macScreen.*` in cmux.json: Mac Screen tabs' settings for every build
/// (the Development switches are `MacScreenDebugSettings`).
/// - `systemShortcuts` (off by default): while a Mac Screen tab has the
///   keyboard, system shortcuts (Cmd-Tab, Cmd-Space, Mission Control and
///   Spaces, screenshots, Cmd-Q/W/H/M) go to the other Mac instead of acting
///   on this one. Needs Accessibility for cmux.
/// - `shareWithoutAsking` (off by default): the person's standing yes to Share
///   This Mac. On, a share request from the signed-in owner's own CLI, agents
///   or devices turns sharing on with no sheet while Screen Recording is
///   granted; each device's access still decides who views or controls.
///   Finishing the Share This Mac sheet once turns it on; MDM can force it.
public nonisolated struct MacScreenSettings: Sendable, Equatable {
    public var systemShortcuts = MacScreenSettings.systemShortcutsDefault
    public var shareWithoutAsking = MacScreenSettings.shareWithoutAskingDefault

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["macScreen"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("systemShortcuts") { settings.systemShortcuts = value }
        if let value = reader.bool("shareWithoutAsking") { settings.shareWithoutAsking = value }
        diagnostics = reader.diagnostics
        return settings
    }
}
