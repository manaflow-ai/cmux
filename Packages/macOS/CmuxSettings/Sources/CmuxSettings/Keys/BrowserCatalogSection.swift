import Foundation

/// Settings under the dotted-id prefix `browser.*`.
public struct BrowserCatalogSection: SettingCatalogSection {
    public let defaultEngine = DefaultsKey<BrowserEngineOption>(
        id: "browser.defaultEngine",
        defaultValue: .auto,
        userDefaultsKey: "browser.defaultEngine",
        legacyUserDefaultsKeys: ["browser.engine"]
    )

    public let chromiumExtensionDirectories = DefaultsKey<String>(
        id: "browser.chromiumExtensionDirectories",
        defaultValue: "",
        userDefaultsKey: "browser.chromiumExtensionDirectories"
    )

    public let remoteDebuggingPort = DefaultsKey<Int>(
        id: "browser.remoteDebuggingPort",
        defaultValue: 0,
        userDefaultsKey: "browser.remoteDebuggingPort"
    )

    public let defaultSearchEngine = DefaultsKey<BrowserSearchEngine>(
        id: "browser.defaultSearchEngine",
        defaultValue: BrowserSearchSettingsStore.defaultSearchEngine,
        userDefaultsKey: BrowserSearchSettingsStore.searchEngineKey
    )

    public let customSearchEngineName = DefaultsKey<String>(
        id: "browser.customSearchEngineName",
        defaultValue: BrowserSearchSettingsStore.defaultCustomSearchEngineName,
        userDefaultsKey: BrowserSearchSettingsStore.customSearchEngineNameKey
    )

    public let customSearchEngineURLTemplate = DefaultsKey<String>(
        id: "browser.customSearchEngineURLTemplate",
        defaultValue: BrowserSearchSettingsStore.defaultCustomSearchEngineURLTemplate,
        userDefaultsKey: BrowserSearchSettingsStore.customSearchEngineURLTemplateKey
    )

    public let showSearchSuggestions = DefaultsKey<Bool>(
        id: "browser.showSearchSuggestions",
        defaultValue: BrowserSearchSettingsStore.defaultSearchSuggestionsEnabled,
        userDefaultsKey: BrowserSearchSettingsStore.searchSuggestionsEnabledKey
    )

    public let theme = DefaultsKey<BrowserThemeMode>(
        id: "browser.theme",
        defaultValue: .system,
        userDefaultsKey: "browserThemeMode"
    )

    /// Default page zoom factor for newly opened browser pages (`1.0` is 100%).
    public let defaultZoomLevel = DefaultsKey<Double>(
        id: "browser.defaultZoomLevel",
        defaultValue: BrowserZoomSettings.defaultLevel,
        userDefaultsKey: BrowserZoomSettings.userDefaultsKey
    )

    public let discardHiddenWebViews = DefaultsKey<Bool>(
        id: "browser.discardHiddenWebViews",
        defaultValue: true,
        userDefaultsKey: "browserHiddenWebViewDiscardEnabled"
    )

    public let hiddenWebViewDiscardDelaySeconds = DefaultsKey<Double>(
        id: "browser.hiddenWebViewDiscardDelaySeconds",
        defaultValue: 300,
        userDefaultsKey: "browserHiddenWebViewDiscardDelaySeconds"
    )

    /// Shows a save panel for each browser download instead of saving directly
    /// to the user's Downloads folder.
    public let askWhereToSaveDownloads = DefaultsKey<Bool>(
        id: "browser.askWhereToSaveDownloads",
        defaultValue: false,
        userDefaultsKey: "browserAskWhereToSaveDownloads"
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
        defaultValue: "localhost\n*.localhost\n127.0.0.1\n::1\n0.0.0.0\n*.localtest.me",
        userDefaultsKey: "browserInsecureHTTPAllowlist"
    )

    /// User/team URL restrictions for every remote embedded-browser navigation.
    /// One host or URL pattern per line; Settings shows loopback development
    /// entries as a suggested starting list. Local absolute `file:` documents
    /// opened through cmux's trusted app-owned navigation path remain available
    /// while this web-origin restriction is active. The restriction becomes
    /// active when a custom value is saved, unless the MDM key
    /// ``BrowserURLAllowlistPolicy/managedDefaultsKey`` is forced.
    public let urlAllowlist = DefaultsKey<String>(
        id: "browser.urlAllowlist",
        defaultValue: BrowserURLAllowlistPolicy.defaultAllowlistText,
        userDefaultsKey: BrowserURLAllowlistPolicy.userDefaultsKey
    )

    public let showImportHintOnBlankTabs = DefaultsKey<Bool>(
        id: "browser.showImportHintOnBlankTabs",
        defaultValue: true,
        userDefaultsKey: "browserImportHintShowOnBlankTabs"
    )

    public let reactGrabVersion = DefaultsKey<String>(
        id: "browser.reactGrabVersion",
        defaultValue: "0.1.29",
        userDefaultsKey: "reactGrabVersion"
    )

    /// Stored under `browserDisabledOverride` — the key the runtime
    /// gate `BrowserAvailabilitySettings.isDisabled()` actually reads.
    /// (The intuitive `browserDisabled` is read by nothing, so the
    /// "Enable cmux Browser" toggle was a no-op until this was aligned.)
    public let disabled = DefaultsKey<Bool>(
        id: "browser.disabled",
        defaultValue: false,
        userDefaultsKey: "browserDisabledOverride"
    )

    public let importHintVariant = DefaultsKey<String>(
        id: "browser.importHintVariant",
        defaultValue: "toolbarChip",
        userDefaultsKey: "browserImportHintVariant"
    )

    public let importHintDismissed = DefaultsKey<Bool>(
        id: "browser.importHintDismissed",
        defaultValue: false,
        userDefaultsKey: "browserImportHintDismissed"
    )

    public init() {}
}
