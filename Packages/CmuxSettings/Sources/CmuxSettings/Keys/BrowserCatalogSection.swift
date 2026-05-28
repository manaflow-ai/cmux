import Foundation

/// Settings under the dotted-id prefix `browser.*`.
public struct BrowserCatalogSection: SettingCatalogSection {
    public let defaultSearchEngine = DefaultsKey<BrowserSearchEngine>(
        id: "browser.defaultSearchEngine",
        defaultValue: .google,
        userDefaultsKey: "browserSearchEngine"
    )

    public let customSearchEngineName = DefaultsKey<String>(
        id: "browser.customSearchEngineName",
        defaultValue: "",
        userDefaultsKey: "browserCustomSearchEngineName"
    )

    public let customSearchEngineURLTemplate = DefaultsKey<String>(
        id: "browser.customSearchEngineURLTemplate",
        defaultValue: "",
        userDefaultsKey: "browserCustomSearchEngineURLTemplate"
    )

    public let showSearchSuggestions = DefaultsKey<Bool>(
        id: "browser.showSearchSuggestions",
        defaultValue: true,
        userDefaultsKey: "browserSearchSuggestionsEnabled"
    )

    public let theme = DefaultsKey<BrowserThemeMode>(
        id: "browser.theme",
        defaultValue: .system,
        userDefaultsKey: "browserThemeMode"
    )

    public let discardHiddenWebViews = DefaultsKey<Bool>(
        id: "browser.discardHiddenWebViews",
        defaultValue: false,
        userDefaultsKey: "browserHiddenWebViewDiscardEnabled"
    )

    public let hiddenWebViewDiscardDelaySeconds = DefaultsKey<Double>(
        id: "browser.hiddenWebViewDiscardDelaySeconds",
        defaultValue: 60,
        userDefaultsKey: "browserHiddenWebViewDiscardDelaySeconds"
    )

    public let openTerminalLinksInCmuxBrowser = DefaultsKey<Bool>(
        id: "browser.openTerminalLinksInCmuxBrowser",
        defaultValue: true,
        userDefaultsKey: "browserOpenTerminalLinksInCmuxBrowser"
    )

    public let interceptTerminalOpenCommandInCmuxBrowser = DefaultsKey<Bool>(
        id: "browser.interceptTerminalOpenCommandInCmuxBrowser",
        defaultValue: true,
        userDefaultsKey: "browserInterceptTerminalOpenCommandInCmuxBrowser"
    )

    public let hostsToOpenInEmbeddedBrowser = DefaultsKey<String>(
        id: "browser.hostsToOpenInEmbeddedBrowser",
        defaultValue: "",
        userDefaultsKey: "browserHostWhitelist"
    )

    public let urlsToAlwaysOpenExternally = DefaultsKey<String>(
        id: "browser.urlsToAlwaysOpenExternally",
        defaultValue: "",
        userDefaultsKey: "browserExternalOpenPatterns"
    )

    public let insecureHttpHostsAllowedInEmbeddedBrowser = DefaultsKey<String>(
        id: "browser.insecureHttpHostsAllowedInEmbeddedBrowser",
        defaultValue: "",
        userDefaultsKey: "browserInsecureHTTPAllowlist"
    )

    public let showImportHintOnBlankTabs = DefaultsKey<Bool>(
        id: "browser.showImportHintOnBlankTabs",
        defaultValue: true,
        userDefaultsKey: "browserImportHintShowOnBlankTabs"
    )

    public let reactGrabVersion = DefaultsKey<String>(
        id: "browser.reactGrabVersion",
        defaultValue: "",
        userDefaultsKey: "reactGrabVersion"
    )

    public init() {}
}
