extension SettingsSchema {
    /// `terminal.fontFamily` and `terminal.fontSize` (Ghostty overrides,
    /// `TerminalFontSetting`), and `terminal.restartLostTerminals`.
    static var terminal: [SettingDescriptor] {
        let sessions = SettingsText.keyed("settings.group.terminalSessions", "Sessions")
        let font = SettingsText.keyed("settings.group.terminalFont", "Font")
        let ghostty = SettingsText.keyed("settings.default.ghosttyConfig", "Ghostty config")
        return [
            SettingDescriptor(
                RestartLostTerminalsSetting.configPath, section: .terminal, group: sessions,
                title: SettingsText.keyed("settings.terminal.restartLostTerminals", "Restart Lost Terminals"),
                help: SettingsText.keyed("settings.terminal.restartLostTerminals.help",
                                         "When a terminal's host is lost, start a new shell in the same tab and folder."),
                kind: .toggle, default: .bool(RestartLostTerminalsSetting.fallback),
                keywords: ["restart", "relaunch", "respawn", "lost", "crash", "dead", "shell", "session"]
            ),
            SettingDescriptor(
                TerminalFontSetting().familyPath, section: .terminal, group: font,
                title: SettingsText.keyed("settings.terminal.fontFamily", "Font Family"),
                help: SettingsText.keyed("settings.terminal.fontFamily.help", "A monospaced font installed on this Mac."),
                kind: .fontFamily, default: nil, defaultLabel: ghostty,
                keywords: ["font", "typeface", "monospace", "monospaced", "font-family", "ghostty"]
            ),
            SettingDescriptor(
                TerminalFontSetting().sizePath, section: .terminal, group: font,
                title: SettingsText.keyed("settings.terminal.fontSize", "Font Size"),
                kind: .number(SettingNumber(TerminalFontSetting().sizeRange, step: 1, unit: .points, placeholder: 13)),
                default: nil, defaultLabel: ghostty,
                keywords: ["font", "text", "size", "zoom", "font-size", "ghostty"]
            ),
        ]
    }
}
