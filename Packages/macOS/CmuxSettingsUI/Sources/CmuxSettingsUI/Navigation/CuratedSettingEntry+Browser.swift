import Foundation

extension CuratedSettingEntry {
    static var browserEntries: [CuratedSettingEntry] {
        [
            // Browser
            .init(section: .browser, id: "enable-browser", title: String(localized: "settings.browser.enabled", defaultValue: "Enable cmux Browser"), synonyms: "Enable cmux Browser browser.disabled enable disable webview embedded browser tabs links"),
            .init(section: .browser, id: "search-engine", title: String(localized: "settings.browser.searchEngine", defaultValue: "Default Search Engine"), synonyms: "Default Search Engine browser.defaultSearchEngine omnibar address bar google duckduckgo bing kagi brave startpage perplexity exa yahoo ecosia qwant mojeek wikipedia github baidu yandex custom search provider engine name url template"),
            .init(section: .browser, id: "search-suggestions", title: String(localized: "settings.browser.searchSuggestions", defaultValue: "Show Search Suggestions"), synonyms: "Show Search Suggestions browser.showSearchSuggestions suggest autocomplete address bar search suggestions"),
            .init(section: .browser, id: "theme", title: String(localized: "settings.browser.theme", defaultValue: "Browser Theme"), synonyms: "Browser Theme browser.theme web page theme color scheme light dark system"),
            .init(section: .browser, id: "hidden-webview-discard", title: String(localized: "settings.browser.hiddenWebViewDiscard", defaultValue: "Browser Memory Saver"), synonyms: "Browser Memory Saver browser.discardHiddenWebViews memory hidden tabs webview discard unload reclaim"),
            .init(section: .browser, id: "hidden-webview-discard-delay", title: String(localized: "settings.browser.hiddenWebViewDiscardDelay", defaultValue: "Memory Saver Delay"), synonyms: "Memory Saver Delay browser.hiddenWebViewDiscardDelaySeconds memory hidden tabs delay seconds discard unload"),
            .init(
                section: .browser,
                id: "ask-where-to-save-downloads",
                title: String(localized: "settings.browser.askWhereToSaveDownloads", defaultValue: "Ask Where to Save Downloads"),
                detailText: String(localized: "settings.browser.askWhereToSaveDownloads.subtitle", defaultValue: "When off, browser downloads save directly to Downloads without a save panel."),
                synonyms: String(localized: "settings.search.alias.setting.browser.ask-where-to-save-downloads", defaultValue: "browser.askWhereToSaveDownloads downloads save panel folder attachments files pdf gmail")
            ),
            .init(section: .browser, id: "terminal-links", title: String(localized: "settings.browser.openTerminalLinks", defaultValue: "Open Terminal Links in cmux Browser"), synonyms: "Open Terminal Links in cmux Browser browser.openTerminalLinksInCmuxBrowser click url terminal links open in browser href"),
            .init(section: .browser, id: "intercept-open", title: String(localized: "settings.browser.interceptOpen", defaultValue: "Intercept open http(s) in Terminal"), synonyms: "Intercept open http(s) in Terminal browser.interceptTerminalOpenCommandInCmuxBrowser open command http https url terminal intercept"),
            .init(section: .browser, id: "host-whitelist", title: String(localized: "settings.browser.hostWhitelist", defaultValue: "Hosts to Open in Embedded Browser"), synonyms: "Hosts to Open in Embedded Browser browser.hostsToOpenInEmbeddedBrowser allowlist whitelist host wildcard domain embedded browser"),
            .init(section: .browser, id: "external-patterns", title: String(localized: "settings.browser.externalPatterns", defaultValue: "URLs to Always Open Externally"), synonyms: "URLs to Always Open Externally browser.urlsToAlwaysOpenExternally denylist blocklist regex rules external default browser"),
            .init(section: .browser, id: "http-allowlist", title: String(localized: "settings.browser.httpAllowlist", defaultValue: "HTTP Hosts Allowed in Embedded Browser"), synonyms: "HTTP Hosts Allowed in Embedded Browser browser.insecureHttpHostsAllowedInEmbeddedBrowser insecure http allowlist localhost localtest non-https warning"),
            .init(
                section: .browser,
                id: "url-allowlist",
                title: String(localized: "settings.browser.urlAllowlist", defaultValue: "Embedded Browser URL Allowlist"),
                synonyms: String(localized: "settings.search.alias.setting.browser.url-allowlist", defaultValue: "browser.urlAllowlist URL allowlist localhost wildcard scheme port organization policy")
            ),
            .init(section: .browser, id: "react-grab", title: String(localized: "settings.browser.reactGrabVersion", defaultValue: "React Grab Version"), synonyms: "React Grab Version browser.reactGrabVersion react grab npm version toolbar cmd-shift-g inspect component"),
            .init(section: .browser, id: "history", title: String(localized: "settings.browser.history", defaultValue: "Browsing History"), synonyms: "Browsing History browsing history clear visited pages omnibar suggestions delete"),
            .init(section: .browser, id: "terminal-link-placement", title: String(localized: "settings.browser.terminalLinkPlacement", defaultValue: "Terminal Link Placement"), paths: ["browser.terminalLinkBrowserPlacement"], synonyms: String(localized: "settings.browser.terminalLinkPlacement.search", defaultValue: "terminal link browser placement same pane tab split open URL")),
        ]
    }
}
