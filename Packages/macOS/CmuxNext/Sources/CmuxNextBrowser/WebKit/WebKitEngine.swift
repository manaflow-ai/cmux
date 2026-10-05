import AppKit
public import Foundation
public import WebKit
public import CmuxNextDesign

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
    /// Hosts whose warnings were turned on again, per profile, until a page
    /// of theirs verifies (WebKitEngine+CertificateWarnings.swift).
    var certificateRechecks: [BrowserProfileID: Set<String>] = [:]
    /// Low Power Mode keeps every open and new tab near 60 fps.
    public let lowPowerMode: LowPowerMode
    private var lowPowerModeObservation: LowPowerModeObservation?
    /// Open tabs, which follow a Low Power Mode change.
    private let openTabs = NSHashTable<WebKitTab>.weakObjects()
    /// The highest rate of a window's display (tests replace it).
    var displayFramesPerSecond: (NSWindow) -> Int = { $0.screen?.maximumFramesPerSecond ?? 60 }
    /// Re-showing a live page after a rate change: nil snapshot takes
    /// WebKit's; the clock times its steps (tests replace both).
    var rateReshowSnapshot: (() async -> NSImage?)?
    var rateReshowClock: any Clock<Duration> = ContinuousClock()
    /// Per-profile site permissions, shared with the Chromium engine.
    public var siteSettings: SiteSettingsRegistry = .shared
    /// Browser passkey authorization (one per app; tests inject a fake).
    public var passkeyAuthorization: WebKitPasskeyAuthorization = .shared
    /// Appended to WebKit's user agent, e.g. "cmux/1.0 Safari/605.1.15".
    public var applicationNameForUserAgent: String?
    /// What modified link clicks do (cmux.json `browser.links.*`). Read on
    /// each click.
    public var linkClicks: BrowserLinkClickMapping = .chrome

    public init(
        profileStore: WebKitProfileStore = WebKitProfileStore(),
        faviconLoader: any BrowserFaviconLoading = BrowserFaviconLoader.shared,
        downloadsDirectory: URL = DownloadDestination.defaultDirectory,
        applicationNameForUserAgent: String? = "Version/26.0 Safari/605.1.15",
        lowPowerMode: LowPowerMode = .system
    ) {
        self.profileStore = profileStore
        self.faviconLoader = faviconLoader
        self.downloadsDirectory = downloadsDirectory
        self.applicationNameForUserAgent = applicationNameForUserAgent
        self.lowPowerMode = lowPowerMode
        lowPowerModeObservation = lowPowerMode.observe { [weak self] enabled in
            self?.applyRenderRate(lowPowerMode: enabled)
        }
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
        openTabs.add(tab)
        if let url = configuration.initialURL {
            tab.load(url)
        }
        return tab
    }

    /// Every open tab takes the rate for the new Low Power Mode state.
    private func applyRenderRate(lowPowerMode: Bool) {
        for tab in openTabs.allObjects {
            applyRenderRate(fullRate: WebKitRenderRate.prefersFullRate(lowPowerMode: lowPowerMode), to: tab)
        }
    }

    /// Sets `tab` to the display's full rate or near 60 fps. WebKit reads the
    /// rate only when the page's visibility changes, so a page on screen is
    /// re-shown under a snapshot when its rate changes there; a page off
    /// screen takes the rate when it is next shown.
    private func applyRenderRate(fullRate: Bool, to tab: WebKitTab) {
        let webView = tab.webView, preferences = webView.configuration.preferences
        // A WebKit without the feature has no rate to change.
        guard !tab.isClosed, let near60 = preferences.isWebKitFeatureEnabled(WebKitRenderRate.near60FPSFeature),
              near60 == fullRate, WebKitRenderRate.apply(fullRate: fullRate, to: preferences),
              let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return }
        // A display at 60 Hz or less renders the same either way: no re-show.
        let display = displayFramesPerSecond(window)
        guard WebKitRenderRate.framesPerSecond(lowPowerMode: !fullRate, displayMaxFPS: display)
                != WebKitRenderRate.framesPerSecond(lowPowerMode: fullRate, displayMaxFPS: display) else { return }
        let snapshot = rateReshowSnapshot ?? { [weak webView] in try? await webView?.takeSnapshot(configuration: nil) }
        tab.rateReshow = WebKitRenderRate.reshow(webView, replacing: tab.rateReshow, snapshot: snapshot, clock: rateReshowClock)
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
        // Power Mode. Open tabs follow a later change (applyRenderRate).
        WebKitRenderRate.apply(fullRate: WebKitRenderRate.prefersFullRate(lowPowerMode: lowPowerMode.isEnabled),
                               to: configuration.preferences)
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
