extension SettingsSchema {
    /// `tabs.newTabKind`: what Cmd-T and the strip's + button open.
    static func newTabKind(group: String) -> SettingDescriptor {
        SettingDescriptor(
            NewTabDefaultKind.configPath, section: .general, group: group,
            title: SettingsText.text("settings.tabs.newTabKind", "New Tab Opens"),
            help: SettingsText.text("settings.tabs.newTabKind.help",
                                    "What Cmd-T and the + button open. Auto picks the kind you last opened in that folder."),
            kind: .choice([
                SettingChoice(NewTabDefaultKind.sameKind.rawValue, SettingsText.text("settings.choice.newTabSameKind", "Same Kind as Current Tab")),
                SettingChoice(NewTabDefaultKind.terminal.rawValue, SettingsText.text("settings.choice.newTabTerminal", "Terminal")),
                SettingChoice(NewTabDefaultKind.browser.rawValue, SettingsText.text("settings.choice.newTabBrowser", "Browser")),
                SettingChoice(NewTabDefaultKind.agent.rawValue, SettingsText.text("settings.choice.newTabAgent", "Agent")),
                SettingChoice(NewTabDefaultKind.page.rawValue, SettingsText.text("settings.choice.newTabPage", "New Tab Page")),
                SettingChoice(NewTabDefaultKind.auto.rawValue, SettingsText.text("settings.choice.newTabAuto", "Auto")),
            ]),
            default: .string(NewTabDefaultKind.fallback.rawValue),
            keywords: ["new tab", "cmd-t", "terminal", "browser", "agent", "kind", "default"]
        )
    }
}
