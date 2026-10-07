extension SettingsSchema {
    static var shortcutHints: [SettingDescriptor] {
        [SettingDescriptor(
            ModifierHoldHintsSetting().configPath, section: .keyboard,
            group: SettingsText.keyed("settings.shortcuts.hintsGroup", "Shortcut Hints"),
            title: SettingsText.keyed("settings.shortcuts.showModifierHoldHints", "Show Shortcuts When Holding a Modifier"),
            help: SettingsText.keyed("settings.shortcuts.showModifierHoldHints.help", "Hold Command or Control for 0.30 seconds to show shortcut hints."),
            kind: .toggle, default: .bool(ModifierHoldHintsSetting().fallback),
            keywords: ["command", "control", "hold", "hints", "keyboard"]
        )]
    }
}
