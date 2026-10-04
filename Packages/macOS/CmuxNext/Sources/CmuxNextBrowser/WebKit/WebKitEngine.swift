public import Foundation
public import WebKit

/// The WebKit engine: one `WKWebView` per tab, one persistent
/// `WKWebsiteDataStore` per profile.
public final class WebKitEngine: BrowserEngine {
    public let kind: BrowserEngineKind = .webkit
    public let availability: BrowserEngineAvailability = .available
    public let capabilities: BrowserCapabilities = [
        .devTools, .downloads, .paneFullscreen, .snapshots, .findMatchCount,
    ]

    public let profileStore: WebKitProfileStore
    public let faviconLoader: any BrowserFaviconLoading
    /// Where downloads go. Read when each download starts.
    public var downloadsDirectory: URL
    /// Per-profile site permissions, shared with the Chromium engine.
    public var siteSettings: SiteSettingsRegistry = .shared
    /// Appended to WebKit's user agent, e.g. "cmux/1.0 Safari/605.1.15".
    public var applicationNameForUserAgent: String?

    public init(
        profileStore: WebKitProfileStore = WebKitProfileStore(),
        faviconLoader: any BrowserFaviconLoading = BrowserFaviconLoader.shared,
        downloadsDirectory: URL = DownloadDestination.defaultDirectory,
        applicationNameForUserAgent: String? = "Version/26.0 Safari/605.1.15"
    ) {
        self.profileStore = profileStore
        self.faviconLoader = faviconLoader
        self.downloadsDirectory = downloadsDirectory
        self.applicationNameForUserAgent = applicationNameForUserAgent
    }

    public func makeTab(_ configuration: BrowserTabConfiguration) async throws -> any BrowserTab {
        try makeWebKitTab(configuration)
    }

    /// Synchronous tab creation. Refuses a configuration with a machine
    /// store (a proxied tab): WebKit cannot send loopback requests to a
    /// per-store proxy (remote-localhost.md section 7), so it would load
    /// this Mac's localhost.
    public func makeWebKitTab(_ configuration: BrowserTabConfiguration) throws(BrowserEngineError) -> WebKitTab {
        guard configuration.machineStore == nil else { throw .machineStoreRequiresChromium }
        return makeTab(unproxied: configuration, webViewConfiguration: nil)
    }

    /// A tab that cannot carry a machine store. `webViewConfiguration` is set
    /// only for page-opened windows, where WebKit hands over the
    /// configuration that links the new page to its opener.
    public func makeWebKitTab(id: BrowserTabID = .random(), profile: BrowserProfileID = .default, initialURL: URL? = nil,
                              zoom: Double = 1, webViewConfiguration: WKWebViewConfiguration? = nil) -> WebKitTab {
        makeTab(unproxied: BrowserTabConfiguration(id: id, profile: profile, initialURL: initialURL, zoom: zoom),
                webViewConfiguration: webViewConfiguration)
    }

    private func makeTab(unproxied configuration: BrowserTabConfiguration, webViewConfiguration: WKWebViewConfiguration?) -> WebKitTab {
        let webConfiguration = webViewConfiguration ?? makeConfiguration(for: configuration.profile)
        prepare(webConfiguration)
        let tab = WebKitTab(configuration: configuration, webViewConfiguration: webConfiguration, engine: self,
                            openedByPage: webViewConfiguration != nil)
        if let url = configuration.initialURL {
            tab.load(url)
        }
        return tab
    }

    private func makeConfiguration(for profile: BrowserProfileID) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profileStore.dataStore(for: profile)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.applicationNameForUserAgent = applicationNameForUserAgent
        return configuration
    }

    /// Settings every tab needs, including page-opened ones.
    private func prepare(_ configuration: WKWebViewConfiguration) {
        // Native element fullscreen takes over the display; the pane shim
        // replaces it (PaneFullscreenScript).
        configuration.preferences.isElementFullscreenEnabled = false
        // Private preference: enables "Inspect Element" in the context menu.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Every tab gets its own controller. A page-opened configuration is a
        // copy of the opener's and would otherwise share its message handlers.
        configuration.userContentController = WKUserContentController()
    }
}
