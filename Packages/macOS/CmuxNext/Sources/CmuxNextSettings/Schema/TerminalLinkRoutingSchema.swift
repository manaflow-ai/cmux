import CmuxNextDesign

/// The Settings rows of `TerminalLinkRouting` (Browser > Terminal Links), classic
/// cmux's keys, kept out of `SettingsSchema` so its catalog stays within the type budget.
nonisolated enum TerminalLinkRoutingSchema {
    static var descriptors: [SettingDescriptor] {
        let group = SettingsText.keyed("settings.group.terminalLinks", "Terminal Links")
        let fallback = TerminalLinkRouting.fallback
        return [
            SettingDescriptor(
                TerminalLinkRouting.openPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.openTerminalLinks", "Open Terminal Links in cmux Browser"),
                help: SettingsText.keyed("settings.browser.openTerminalLinks.help",
                                         "When off, links clicked in terminal output open in your default browser."),
                kind: .toggle, default: .bool(fallback.opensInCmuxBrowser), keywords: ["link", "url", "click", "default browser"]
            ),
            SettingDescriptor(
                TerminalLinkRouting.hostsPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.hostWhitelist", "Hosts to Open in Embedded Browser"),
                help: SettingsText.keyed("settings.browser.hostWhitelist.help",
                                         "Only these hosts open in cmux, such as example.com or *.example.com. Empty opens every host in cmux."),
                summary: SettingsText.keyed("settings.browser.hostWhitelist.summary", "Empty opens every host in cmux"),
                kind: .hostList, default: .array([]), keywords: ["allowlist", "whitelist", "domain", "link"]
            ),
            SettingDescriptor(
                TerminalLinkRouting.rulesPath, section: .browser, group: group,
                title: SettingsText.keyed("settings.browser.externalPatterns", "URLs to Always Open Externally"),
                help: SettingsText.keyed("settings.browser.externalPatterns.help",
                                         "Terminal links that match open in your default browser. Text matches anywhere in the URL, * and ? are wildcards, and re: starts a regular expression."),
                summary: SettingsText.keyed("settings.browser.externalPatterns.summary", "Terminal links that open in your default browser"),
                kind: .stringList, default: .array([]), keywords: ["denylist", "blocklist", "regex", "external", "default browser"]
            ),
        ]
    }
}
