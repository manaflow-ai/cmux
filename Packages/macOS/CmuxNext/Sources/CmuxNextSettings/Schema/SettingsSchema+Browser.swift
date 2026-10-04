import CmuxNextDesign

/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum BrowserSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let engine = SettingsText.keyed("settings.group.engine", "Engine")
        let memory = SettingsText.keyed("settings.group.memory", "Memory")
        let remote = SettingsText.keyed("settings.group.remote", "Remote Machines")
        let bookmarks = SettingsText.keyed("settings.group.bookmarks", "Bookmarks")
        return [
            SettingDescriptor(
                BrowserDefaultEngine.configPath, section: .browser, group: engine,
                title: SettingsText.keyed("settings.browser.defaultEngine", "Default Engine"),
                help: SettingsText.keyed("settings.browser.defaultEngine.help", "New browser tabs open in this engine."),
                kind: .choice([
                    SettingChoice(BrowserDefaultEngine.chromium.rawValue, "Chromium"),
                    SettingChoice(BrowserDefaultEngine.webkit.rawValue, "WebKit"),
                ]),
                default: .string(BrowserDefaultEngine.fallback.rawValue), keywords: ["chrome", "safari", "cef"]
            ),
            SettingDescriptor(
                BrowserNewTabPage.configPath, section: .browser, group: engine,
                title: SettingsText.keyed("settings.browser.newTabPage", "New Tab Page"),
                help: SettingsText.keyed("settings.browser.newTabPage.help", "An address such as https://example.com. Empty opens a blank page."),
                kind: .url, default: .string(BrowserNewTabPage.fallback), keywords: ["home", "start page", "url"]
            ),
            SettingDescriptor(
                BookmarksBarSetting.configPath, section: .browser, group: bookmarks,
                title: SettingsText.keyed("settings.browser.showBookmarksBar", "Show Bookmarks Bar"),
                help: SettingsText.keyed("settings.browser.showBookmarksBar.help", "A row of bookmarks under each browser toolbar."),
                kind: .toggle, default: .bool(false), keywords: ["bookmarks", "favorites", "bar"]
            ),
            SettingDescriptor(
                BrowserHibernationSetting.configPath, section: .browser, group: memory,
                title: SettingsText.keyed("settings.browser.hibernation", "Hibernate Hidden Tabs"),
                help: SettingsText.keyed("settings.browser.hibernation.help", "Frees memory; history and position are kept."),
                kind: .choiceOrNumber([
                    SettingChoice("moderate", SettingsText.keyed("settings.choice.moderate", "After 1 Hour")),
                    SettingChoice("aggressive", SettingsText.keyed("settings.choice.aggressive", "After 10 Minutes")),
                    SettingChoice("off", SettingsText.keyed("settings.choice.never", "Never")),
                ], SettingNumber(1...1_440, step: 5, unit: .minutes, placeholder: 30)),
                default: .string("moderate"), keywords: ["memory saver", "sleep", "discard"]
            ),
            SettingDescriptor(
                ["browser", "hibernationExclusions"], section: .browser, group: memory,
                title: SettingsText.keyed("settings.browser.hibernationExclusions", "Never Hibernate"),
                help: SettingsText.keyed("settings.browser.hibernationExclusions.help", "Hosts such as mail.google.com or *.example.com."),
                kind: .hostList, default: .array([])
            ),
            SettingDescriptor(
                ["browser", "hibernatePinnedTabs"], section: .browser, group: memory,
                title: SettingsText.keyed("settings.browser.hibernatePinnedTabs", "Hibernate Pinned Tabs"),
                kind: .toggle, default: .bool(BrowserHibernationSetting.fallback.includesPinnedTabs)
            ),
            SettingDescriptor(
                ["browser", "remoteLocalhost"], section: .browser, group: remote,
                title: SettingsText.keyed("settings.browser.remoteLocalhost", "Open localhost on the Workspace's Machine"),
                kind: .toggle, default: .bool(RemoteLocalhostSetting.fallback.enabled), keywords: ["ssh", "cloud", "port"]
            ),
        ] + BrowserLinkClickSchema.descriptors
    }
}
