import CmuxNextDesign

extension SettingsSchema {
    static var browser: [SettingDescriptor] {
        let engine = SettingsText.text("settings.group.engine", "Engine")
        let memory = SettingsText.text("settings.group.memory", "Memory")
        let remote = SettingsText.text("settings.group.remote", "Remote Machines")
        return [
            SettingDescriptor(
                BrowserDefaultEngine.configPath, section: .browser, group: engine,
                title: SettingsText.text("settings.browser.defaultEngine", "Default Engine"),
                help: SettingsText.text("settings.browser.defaultEngine.help", "New browser tabs open in this engine."),
                kind: .choice([
                    SettingChoice(BrowserDefaultEngine.chromium.rawValue, "Chromium"),
                    SettingChoice(BrowserDefaultEngine.webkit.rawValue, "WebKit"),
                ]),
                default: .string(BrowserDefaultEngine.fallback.rawValue), keywords: ["chrome", "safari", "cef"]
            ),
            SettingDescriptor(
                BrowserNewTabPage.configPath, section: .browser, group: engine,
                title: SettingsText.text("settings.browser.newTabPage", "New Tab Page"),
                help: SettingsText.text("settings.browser.newTabPage.help", "An address such as https://example.com. Empty opens a blank page."),
                kind: .url, default: .string(BrowserNewTabPage.fallback), keywords: ["home", "start page", "url"]
            ),
            SettingDescriptor(
                BrowserHibernationSetting.configPath, section: .browser, group: memory,
                title: SettingsText.text("settings.browser.hibernation", "Hibernate Hidden Tabs"),
                help: SettingsText.text("settings.browser.hibernation.help", "Frees memory; history and position are kept."),
                kind: .choiceOrNumber([
                    SettingChoice("moderate", SettingsText.text("settings.choice.moderate", "After 1 Hour")),
                    SettingChoice("aggressive", SettingsText.text("settings.choice.aggressive", "After 10 Minutes")),
                    SettingChoice("off", SettingsText.text("settings.choice.never", "Never")),
                ], SettingNumber(1...1_440, step: 5, unit: .minutes, placeholder: 30)),
                default: .string("moderate"), keywords: ["memory saver", "sleep", "discard"]
            ),
            SettingDescriptor(
                ["browser", "hibernationExclusions"], section: .browser, group: memory,
                title: SettingsText.text("settings.browser.hibernationExclusions", "Never Hibernate"),
                help: SettingsText.text("settings.browser.hibernationExclusions.help", "Hosts such as mail.google.com or *.figma.com."),
                kind: .hostList, default: .array([])
            ),
            SettingDescriptor(
                ["browser", "hibernatePinnedTabs"], section: .browser, group: memory,
                title: SettingsText.text("settings.browser.hibernatePinnedTabs", "Hibernate Pinned Tabs"),
                kind: .toggle, default: .bool(BrowserHibernationSetting.fallback.includesPinnedTabs)
            ),
            SettingDescriptor(
                ["browser", "remoteLocalhost"], section: .browser, group: remote,
                title: SettingsText.text("settings.browser.remoteLocalhost", "Open localhost on the Workspace's Machine"),
                kind: .toggle, default: .bool(RemoteLocalhostSetting.fallback.enabled), keywords: ["ssh", "cloud", "port"]
            ),
        ]
    }
}
