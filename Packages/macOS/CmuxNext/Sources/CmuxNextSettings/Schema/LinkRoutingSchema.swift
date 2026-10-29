import CmuxNextDesign

/// The Settings rows of `LinkRouting` (Browser > Opening Links, Enable cmux Browser first) and of `TextEditorSetting`
/// (General > Files), kept out of `SettingsSchema` so its catalog stays within the type budget.
nonisolated enum LinkRoutingSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.openingLinks", "Opening Links")
        let fallback = LinkRouting.fallback
        return [
            SettingDescriptor(
                LinkRouting.enabledPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.enabled", "Enable cmux Browser"),
                help: SettingsText.keyed("settings.browser.enabled.help",
                                         "When off, cmux opens no browser tabs for web pages and every link opens in your default browser."),
                kind: .toggle, default: .bool(fallback.browserEnabled), keywords: ["browser", "disable", "turn off", "default browser", "web"]
            ),
            SettingDescriptor(
                LinkRouting.openPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.openLinks", "Open Links in cmux Browser"),
                help: SettingsText.keyed("settings.browser.openLinks.help",
                                         "When off, links you click in terminals, agent chats, Home and cmux pages open in your default browser. Shift-Command-click opens a link in the other browser."),
                kind: .toggle, default: .bool(fallback.opensInCmuxBrowser), keywords: ["link", "url", "click", "default browser", "terminal", "chat"]
            ),
            SettingDescriptor(
                LinkRouting.signInPagesPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.openSignInPages", "Open Sign-In Pages in cmux Browser"),
                help: SettingsText.keyed("settings.browser.openSignInPages.help",
                                         "Sign-in and device-code pages, such as GitHub's device page or a page gh, aws or an agent opens to sign in, open in a cmux browser tab even when other links open in your default browser. URLs to Always Open Externally still win."),
                kind: .toggle, default: .bool(fallback.signInPagesInCmux),
                keywords: ["sign in", "login", "device code", "oauth", "auth", "passkey", "default browser", "gh auth login"]
            ),
            // Classic's key: read when the new one is absent, never written by Settings. Listed so
            // MDM profiles and team policies written for it still apply.
            SettingDescriptor(
                LinkRouting.legacyOpenPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.openTerminalLinks", "Open Terminal Links in cmux Browser"),
                help: SettingsText.keyed("settings.browser.openTerminalLinks.help",
                                         "When off, links clicked in terminal output open in your default browser."),
                kind: .toggle, default: .bool(fallback.opensInCmuxBrowser), keywords: ["link", "url", "click", "default browser"]
            ).hiddenFromSettingsPage("classic's name for browser.openLinksInCmuxBrowser, read only when that key is absent"),
            SettingDescriptor(
                LinkRouting.hostsPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.hostWhitelist", "Hosts to Open in Embedded Browser"),
                help: SettingsText.keyed("settings.browser.hostWhitelist.help",
                                         "Only these hosts open in cmux, such as example.com or *.example.com. Empty opens every host in cmux."),
                kind: .hostList, default: .array([]), keywords: ["allowlist", "whitelist", "domain", "link"]
            ),
            SettingDescriptor(
                LinkRouting.rulesPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.externalPatterns", "URLs to Always Open Externally"),
                help: SettingsText.keyed("settings.browser.externalLinkPatterns.help",
                                         "Links that match open in your default browser. Text matches anywhere in the URL, * and ? are wildcards, and re: starts a regular expression."),
                summary: SettingsText.keyed("settings.browser.externalLinkPatterns.summary", "Links that open in your default browser"),
                kind: .stringList, default: .array([]), keywords: ["denylist", "blocklist", "regex", "external", "default browser"]
            ),
            SettingDescriptor(
                TextEditorSetting.configPath, section: .general, group: SettingsText.keyed("settings.group.files", "Files"),
                title: SettingsText.keyed("settings.files.textEditor", "Text Editor"),
                help: SettingsText.keyed("settings.files.textEditor.help",
                                         "The app Open in Text Editor uses for a path: an app name, a bundle ID or the path of an app. Empty uses the app that opens source code."),
                kind: .text, default: .string(""), keywords: ["editor", "open with", "app", "path", "file", "code"]
            ),
        ]
    }
}
