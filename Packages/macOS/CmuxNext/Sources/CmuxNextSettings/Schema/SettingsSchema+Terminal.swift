/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum TerminalSettingsSchema {
    /// `terminal.fontFamily` and `terminal.fontSize` (Ghostty overrides,
    /// `TerminalFontSetting`).
    static var descriptors: [SettingDescriptor] {
        let font = SettingsText.keyed("settings.group.terminalFont", "Font")
        let ghostty = SettingsText.keyed("settings.source.ghostty", "Ghostty")
        return [
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
