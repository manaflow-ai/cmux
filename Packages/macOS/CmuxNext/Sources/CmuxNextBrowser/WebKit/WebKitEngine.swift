public import Foundation
public import WebKit
import CmuxNextDesign

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
    /// Hosts whose untrusted certificate the user chose to proceed past, per
    /// browser profile, until the app quits (never written to disk).
    var certificateExceptions: [BrowserProfileID: Set<String>] = [:]
    /// Low Power Mode keeps new tabs near 60 fps (tests replace it).
    var lowPowerMode: () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled }
    /// Per-profile site permissions, shared with the Chromium engine.
    public var siteSettings: SiteSettingsRegistry = .shared
    /// Browser passkey authorization (one per app; tests inject a fake).
    public var passkeyAuthorization: WebKitPasskeyAuthorization = .shared
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
        makeWebKitTab(configuration)
    }

    /// Synchronous tab creation. `webViewConfiguration` is set only for
    /// page-opened windows, where WebKit hands over the configuration that
    /// links the new page to its opener.
    public func makeWebKitTab(
        _ configuration: BrowserTabConfiguration,
        webViewConfiguration: WKWebViewConfiguration? = nil
    ) -> WebKitTab {
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
        // The display's full rate (120 Hz on ProMotion); near 60 fps in Low
        // Power Mode. Read when each tab is made.
        WebKitRenderRate.apply(fullRate: !lowPowerMode(), to: configuration.preferences)
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
