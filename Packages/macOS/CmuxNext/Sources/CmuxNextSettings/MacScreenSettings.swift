/// `macScreen.*` in cmux.json: Mac Screen tabs' settings for every build
/// (the Development switches are `MacScreenDebugSettings`).
/// - `systemShortcuts` (off by default): while a Mac Screen tab has the
///   keyboard, system shortcuts (Cmd-Tab, Cmd-Space, Mission Control and
///   Spaces, screenshots, Cmd-Q/W/H/M) go to the other Mac instead of acting
///   on this one. Needs Accessibility for cmux.
public nonisolated struct MacScreenSettings: Sendable, Equatable {
    public static let systemShortcutsPath = ["macScreen", "systemShortcuts"]
    public var systemShortcuts = false

    public init() {}

    static func parse(_ root: JSONValue, diagnostics: inout [SettingsDiagnostic]) -> Self {
        var settings = Self()
        guard var reader = ConfigFieldReader(root, at: ["macScreen"], diagnostics: &diagnostics) else { return settings }
        if let value = reader.bool("systemShortcuts") { settings.systemShortcuts = value }
        diagnostics = reader.diagnostics
        return settings
    }
}

/// Keyboard > Mac Screen.
nonisolated enum MacScreenSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.macScreenKeyboard", "Mac Screen")
        return [
            SettingDescriptor(
                MacScreenSettings.systemShortcutsPath, section: .keyboard, group: group,
                title: SettingsText.keyed("settings.macScreen.systemShortcuts", "Send System Shortcuts to the Remote Mac"),
                help: SettingsText.keyed("settings.macScreen.systemShortcuts.help",
                                         "While a Mac Screen tab has the keyboard, shortcuts like ⌘Tab, ⌘Space, Mission Control and ⌘Q go to the other Mac. Needs Accessibility."),
                summary: SettingsText.keyed("settings.macScreen.systemShortcuts.summary", "System shortcuts go to the remote Mac"),
                kind: .toggle, default: .bool(MacScreenSettings().systemShortcuts),
                keywords: ["mac screen", "remote", "system shortcuts", "command tab", "spotlight", "mission control", "keyboard", "accessibility"]
            ),
        ]
    }
}
