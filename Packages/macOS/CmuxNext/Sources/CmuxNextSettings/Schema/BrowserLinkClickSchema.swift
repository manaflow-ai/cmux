import CmuxNextDesign

/// The Settings rows of `browser.links.*` (Browser > Links), kept out of
/// `SettingsSchema` so its catalog stays within the type budget.
nonisolated enum BrowserLinkClickSchema {
    /// Agents may set every `browser.links.*` key (no network, privacy or
    /// destructive effect).
    static var agentSettableKeys: Set<String> {
        Set(BrowserLinkClickSetting.keys.map { "browser.links.\($0.name)" })
    }

    /// `browser.links.*`: what each modified link click does (Chrome's
    /// defaults), one choice row each.
    static var descriptors: [SettingDescriptor] {
        let links = SettingsText.keyed("settings.group.links", "Links")
        let choices = [
            SettingChoice(BrowserLinkClickSetting.Action.backgroundTab.rawValue,
                          SettingsText.keyed("settings.choice.link.backgroundTab", "New Background Tab")),
            SettingChoice(BrowserLinkClickSetting.Action.foregroundTab.rawValue,
                          SettingsText.keyed("settings.choice.link.foregroundTab", "New Tab")),
            SettingChoice(BrowserLinkClickSetting.Action.newWindow.rawValue,
                          SettingsText.keyed("settings.choice.link.newWindow", "New Window")),
            SettingChoice(BrowserLinkClickSetting.Action.currentTab.rawValue,
                          SettingsText.keyed("settings.choice.link.currentTab", "Current Tab")),
            SettingChoice(BrowserLinkClickSetting.Action.download.rawValue,
                          SettingsText.keyed("settings.choice.link.download", "Download")),
        ]
        let downloadHelp = SettingsText.keyed("settings.browser.links.downloadHelp", "In Chromium tabs, Download keeps Chrome's default.")
        let rows: [(String, SettingText, SettingText?, [String])] = [
            ("cmdClick", SettingsText.keyed("settings.browser.links.cmdClick", "Command-Click"), downloadHelp, ["cmd", "command"]),
            ("cmdShiftClick", SettingsText.keyed("settings.browser.links.cmdShiftClick", "Shift-Command-Click"),
             SettingsText.keyed("settings.browser.links.cmdShiftClick.help", "Shift-middle-click does the same."), ["cmd", "shift"]),
            ("shiftClick", SettingsText.keyed("settings.browser.links.shiftClick", "Shift-Click"), downloadHelp, ["shift"]),
            ("optionClick", SettingsText.keyed("settings.browser.links.optionClick", "Option-Click"),
             SettingsText.keyed("settings.browser.links.optionClick.help", "Chromium tabs always download."), ["option", "alt"]),
            ("middleClick", SettingsText.keyed("settings.browser.links.middleClick", "Middle-Click"),
             SettingsText.keyed("settings.browser.links.middleClick.help", "Chromium tabs use the Command-Click setting."), ["middle", "wheel"]),
        ]
        let fallback = BrowserLinkClickSetting.fallback
        return rows.map { row in
            let (key, title, help, keywords) = row
            let field = BrowserLinkClickSetting.keys.first(where: { $0.name == key }).map(\.field) ?? \.cmdClick
            return SettingDescriptor(
                BrowserLinkClickSetting.configPath + [key], section: .browser, group: links, title: title, help: help,
                kind: .choice(choices), default: .string(fallback[keyPath: field].rawValue), keywords: ["link"] + keywords
            )
        }
    }
}
