extension SettingsSchema {
    /// `terminal.fontFamily` and `terminal.fontSize` (Ghostty overrides,
    /// `TerminalFontSetting`), and `terminal.restartLostTerminals`.
    static var terminal: [SettingDescriptor] {
        let sessions = SettingsText.text("settings.group.terminalSessions", "Sessions")
        let font = SettingsText.text("settings.group.terminalFont", "Font")
        let ghostty = SettingsText.text("settings.default.ghosttyConfig", "Ghostty config")
        return [
            SettingDescriptor(
                RestartLostTerminalsSetting.configPath, section: .terminal, group: sessions,
                title: SettingsText.text("settings.terminal.restartLostTerminals", "Restart Lost Terminals"),
                help: SettingsText.text("settings.terminal.restartLostTerminals.help",
                                        "When a terminal's host is lost, start a new shell in the same tab and folder."),
                kind: .toggle, default: .bool(RestartLostTerminalsSetting.fallback),
                keywords: ["restart", "relaunch", "respawn", "lost", "crash", "dead", "shell", "session"]
            ),
            SettingDescriptor(
                TerminalFontSetting().familyPath, section: .terminal, group: font,
                title: SettingsText.text("settings.terminal.fontFamily", "Font Family"),
                help: SettingsText.text("settings.terminal.fontFamily.help", "A monospaced font installed on this Mac."),
                kind: .fontFamily, default: nil, defaultLabel: ghostty,
                keywords: ["font", "typeface", "monospace", "monospaced", "font-family", "ghostty"]
            ),
            SettingDescriptor(
                TerminalFontSetting().sizePath, section: .terminal, group: font,
                title: SettingsText.text("settings.terminal.fontSize", "Font Size"),
                kind: .number(SettingNumber(TerminalFontSetting().sizeRange, step: 1, unit: .points, placeholder: 13)),
                default: nil, defaultLabel: ghostty,
                keywords: ["font", "text", "size", "zoom", "font-size", "ghostty"]
            ),
        ]
    }
}
