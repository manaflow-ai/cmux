extension SettingsSchema {
    /// `terminal.fontFamily` and `terminal.fontSize` (Ghostty overrides,
    /// `TerminalFontSetting`).
    static var terminal: [SettingDescriptor] {
        let font = SettingsText.text("settings.group.terminalFont", "Font")
        let ghostty = SettingsText.text("settings.default.ghosttyConfig", "Ghostty config")
        return [
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
