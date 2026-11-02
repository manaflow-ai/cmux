import CmuxNextDesign

/// One group of `SettingsSchema` rows (its own type: the schema type's line budget is per type).
nonisolated enum BrowserSettingsSchema {
    static var descriptors: [SettingDescriptor] {
        let engine = SettingsText.keyed("settings.group.engine", "Engine")
        let memory = SettingsText.keyed("settings.group.memory", "Memory")
        let remote = SettingsText.keyed("settings.group.remote", "Remote Machines")
        let bookmarks = SettingsText.keyed("settings.group.bookmarks", "Bookmarks")
        let toolbar = SettingsText.keyed("settings.group.toolbar", "Toolbar")
        let extensions = SettingsText.keyed("settings.group.extensions", "Extensions")
        let agentInput = SettingsText.keyed("settings.group.agentInput", "Agent Input")
        let importGroup = SettingsText.keyed("settings.group.import", "Import")
        return [
            BrowserToolbarButtonsSetting.descriptor(group: toolbar),
            SettingDescriptor(
                BrowserDefaultEngine.configPath, section: .browser, group: engine,
                title: SettingsText.keyed("settings.browser.defaultEngine", "Browser Engine"),
                help: SettingsText.keyed("settings.browser.defaultEngine.help", "Browser tabs and cmux pages, such as History and Apps, open in this engine."),
                kind: .choice([
                    SettingChoice(BrowserDefaultEngine.chromium.rawValue, "Chromium"),
                    SettingChoice(BrowserDefaultEngine.webkit.rawValue, "WebKit"),
                ]),
                default: .string(BrowserDefaultEngine.fallback.rawValue), keywords: ["chrome", "safari", "cef"]
            ),
            SettingDescriptor(
                BrowserSiteEngines.configPath, section: .browser, group: engine,
                title: SettingsText.keyed("settings.browser.siteEngines", "Site Engines"),
                help: SettingsText.keyed("settings.browser.siteEngines.help",
                                         "Sites that always open in one engine: a site, such as spotify.com, and chromium or webkit. Spotify, Netflix and other protected media sites open in WebKit, because their media does not play in Chromium."),
                kind: .stringMap, default: BrowserSiteEngines.fallback.jsonValue,
                keywords: ["drm", "widevine", "spotify", "netflix", "site", "webkit", "chromium"]
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
                BrowserImportSetting.configPath, section: .browser, group: importGroup,
                title: SettingsText.keyed("settings.browser.importEnabled", "Import from Other Browsers"),
                help: SettingsText.keyed("settings.browser.importEnabled.help",
                                         "Offers to bring bookmarks, history, passwords and sign-ins over from other browsers: Import from Browser in the File menu and the palette, and the import cards in Settings. Off hides them and nothing imports by itself. Data already imported stays."),
                kind: .toggle, default: .bool(BrowserImportSetting.fallback),
                keywords: ["import", "browser", "chrome", "safari", "arc", "firefox", "bookmarks", "history", "passwords", "cookies", "suggestions"]
            ),
            SettingDescriptor(
                BrowserCookieBannerSetting().configPath, section: .browser, group: importGroup,
                title: SettingsText.keyed("settings.browser.importCookieBanner", "Offer to Import Cookies"),
                help: SettingsText.keyed("settings.browser.importCookieBanner.help",
                                         "Browser tabs offer to import cookies from your other browsers, so you stay signed in. Nothing imports until you click Import. Don't Show Again on the banner turns this off."),
                kind: .toggle, default: .bool(BrowserCookieBannerSetting().fallback),
                keywords: ["import", "cookies", "banner", "card", "sign in", "login", "chrome", "safari", "arc", "dismissed", "reset"]
            ),
            SettingDescriptor(
                AgentCursorSetting().configPath, section: .browser, group: agentInput,
                title: SettingsText.keyed("settings.browser.showAgentCursor", "Show Agent Cursor"),
                help: SettingsText.keyed(
                    "settings.browser.showAgentCursor.help",
                    "When an agent drives a browser tab, show its cursor, clicks and typed keys on the page. Password fields show dots."
                ),
                kind: .toggle, default: .bool(AgentCursorSetting().fallback),
                keywords: ["agent", "cursor", "keystrokes", "typing", "automation", "overlay"]
            ),
            SettingDescriptor(
                AgentMouseSetting().motionPath, section: .browser, group: agentInput,
                title: SettingsText.keyed("settings.browser.agentMouseMotion", "Agent Pointer Motion"),
                help: SettingsText.keyed(
                    "settings.browser.agentMouseMotion.help",
                    "How an agent moves the pointer in browser tabs. Human moves along a curved path and rests before each click, as a person does, so pages see hover and timing like a person's. Instant jumps to the target and clicks at once."
                ),
                kind: .choice([
                    SettingChoice("human", SettingsText.keyed("settings.choice.agentMouseHuman", "Human")),
                    SettingChoice("instant", SettingsText.keyed("settings.choice.agentMouseInstant", "Instant")),
                ]),
                default: .string(AgentMouseSetting().fallback.motion.rawValue),
                keywords: ["agent", "mouse", "pointer", "cursor", "human", "motion", "automation"]
            ),
            SettingDescriptor(
                AgentMouseSetting().maxMoveMsPath, section: .browser, group: agentInput,
                title: SettingsText.keyed("settings.browser.agentMouseMaxMove", "Longest Agent Pointer Move"),
                help: SettingsText.keyed(
                    "settings.browser.agentMouseMaxMove.help",
                    "The longest time one agent pointer move takes with human motion. Short moves take less."
                ),
                kind: .number(SettingNumber(AgentMouseSetting().maxMoveMsRange, step: 10, unit: .milliseconds)),
                default: .number(AgentMouseSetting().fallback.maxMoveMs),
                keywords: ["agent", "mouse", "pointer", "speed", "duration"]
            ),
            SettingDescriptor(
                BuiltInAdBlockerSetting().configPath, section: .browser, group: extensions,
                title: SettingsText.keyed("settings.browser.builtInAdBlocker", "Built-in uBlock Origin"),
                help: SettingsText.keyed("settings.browser.builtInAdBlocker.help", "The full uBlock Origin blocks ads and trackers in Chromium tabs. Takes effect after cmux restarts."),
                kind: .toggle, default: .bool(BuiltInAdBlockerSetting().fallback), keywords: ["ublock", "ad blocker", "adblock", "extensions", "trackers"]
            ),
            SettingDescriptor(
                BrowserHibernationSetting.configPath, section: .browser, group: memory,
                title: SettingsText.keyed("settings.browser.hibernation", "Hibernate Hidden Tabs"),
                help: SettingsText.keyed("settings.browser.hibernation.help", "Frees memory; history and position are kept."),
                summary: SettingsText.keyed("settings.browser.hibernation.summary", "Frees memory; history and scroll are kept"),
                kind: .choiceOrNumber([
                    SettingChoice("moderate", SettingsText.keyed("settings.choice.after30Minutes", "After 30 Minutes")),
                    SettingChoice("aggressive", SettingsText.keyed("settings.choice.aggressive", "After 10 Minutes")),
                    SettingChoice("off", SettingsText.keyed("settings.choice.never", "Never")),
                ], SettingNumber(1...1_440, step: 5, unit: .minutes, placeholder: 30)),
                // Unset is its own behaviour, not "moderate": hidden pages only freeze and are never
                // discarded on their own (`BrowserHibernationSetting.fallback`). Any written value,
                // "moderate" included, turns automatic discards on, so it shows as customized and
                // Reset returns to unset.
                default: nil,
                defaultLabel: SettingsText.keyed("settings.default.neverDiscard", "Never Discard"),
                keywords: ["memory saver", "sleep", "discard", "freeze", "reload"]
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
                ["browser", "freezeHiddenTabs"], section: .browser, group: memory,
                title: SettingsText.keyed("settings.browser.freezeHiddenTabs", "Freeze Hidden Tabs"),
                help: SettingsText.keyed(
                    "settings.browser.freezeHiddenTabs.help",
                    "Saves power: a hidden Chromium tab stops running until you show it. Pinned tabs and Never Hibernate hosts stay awake."
                ),
                kind: .choiceOrNumber([
                    SettingChoice("off", SettingsText.keyed("settings.choice.never", "Never")),
                ], SettingNumber(5...3_600, step: 5, unit: .seconds, placeholder: BrowserHibernationSetting.defaultFreezeSeconds)),
                default: .number(BrowserHibernationSetting.defaultFreezeSeconds), keywords: ["power", "battery", "energy", "sleep", "suspend"]
            ),
            SettingDescriptor(
                BrowserHibernationSetting.neighborRadiusPath, section: .browser, group: memory,
                title: SettingsText.keyed("settings.browser.keepNeighborTabsAwake", "Keep Neighbor Tabs Awake"),
                help: SettingsText.keyed(
                    "settings.browser.keepNeighborTabsAwake.help",
                    "Tabs on each side of the shown tab stay loaded and running, so switching to them is instant. 0 turns it off. Memory pressure and Low Power Mode turn it off."
                ),
                kind: .number(SettingNumber(0...3, step: 1, unit: .count)),
                default: .number(Double(BrowserHibernationSetting.defaultNeighborRadius)),
                keywords: ["neighbor", "adjacent", "preload", "warm", "instant", "switch", "hibernation", "freeze"]
            ),
            SettingDescriptor(
                ["browser", "remoteLocalhost"], section: .browser, group: remote,
                title: SettingsText.keyed("settings.browser.remoteLocalhost", "Open localhost on the Workspace's Machine"),
                kind: .toggle, default: .bool(RemoteLocalhostSetting.fallback.enabled), keywords: ["ssh", "cloud", "port"]
            ),
        ] + OmnibarSettingsSchema.descriptors + BrowserLinkClickSchema.descriptors + LinkRoutingSchema.descriptors
            + BrowserPasswordsSettingsSchema.descriptors + BrowserVerificationAutofillSettingsSchema.descriptors
    }
}
