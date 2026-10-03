extension SettingsSchema {
    /// `tabs.newTabKind`: what Cmd-T and the strip's + button open.
    static func newTabKind(group: SettingText) -> SettingDescriptor {
        SettingDescriptor(
            NewTabDefaultKind.configPath, section: .general, group: group,
            title: SettingsText.keyed("settings.tabs.newTabKind", "New Tab Opens"),
            help: SettingsText.keyed("settings.tabs.newTabKind.help",
                                    "What Cmd-T and the + button open. Auto picks the kind you last opened in that folder."),
            kind: .choice([
                SettingChoice(NewTabDefaultKind.sameKind.rawValue, SettingsText.keyed("settings.choice.newTabSameKind", "Same Kind as Current Tab")),
                SettingChoice(NewTabDefaultKind.terminal.rawValue, SettingsText.keyed("settings.choice.newTabTerminal", "Terminal")),
                SettingChoice(NewTabDefaultKind.browser.rawValue, SettingsText.keyed("settings.choice.newTabBrowser", "Browser")),
                SettingChoice(NewTabDefaultKind.agent.rawValue, SettingsText.keyed("settings.choice.newTabAgent", "Agent")),
                SettingChoice(NewTabDefaultKind.page.rawValue, SettingsText.keyed("settings.choice.newTabPage", "New Tab Page")),
                SettingChoice(NewTabDefaultKind.auto.rawValue, SettingsText.keyed("settings.choice.newTabAuto", "Auto")),
            ]),
            default: .string(NewTabDefaultKind.fallback.rawValue),
            keywords: ["new tab", "cmd-t", "terminal", "browser", "agent", "kind", "default"]
        )
    }
}
