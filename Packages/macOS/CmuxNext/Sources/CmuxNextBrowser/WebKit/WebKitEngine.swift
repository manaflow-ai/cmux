import AppKit
public import CmuxNextSignposts
public import CmuxNextWakeups
public import Foundation
public import WebKit
public import CmuxNextDesign
#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextInput
#endif

/// The WebKit engine: one `WKWebView` per tab, one persistent
/// `WKWebsiteDataStore` per profile.
public final class WebKitEngine: BrowserEngine {
    public let kind: BrowserEngineKind = .webkit
    public let availability: BrowserEngineAvailability = .available
    public let capabilities: BrowserCapabilities = [
        .devTools, .downloads, .paneFullscreen, .snapshots, .findMatchCount,
    ]

    public let profileStore: WebKitProfileStore
    /// The App's browser stores, shared with the Chromium engine (``BrowserSharedStores``).
    public let stores: BrowserSharedStores
    public let faviconLoader: any BrowserFaviconLoading
    /// Where downloads go. Read when each download starts.
    public var downloadsDirectory: URL
    /// Hosts whose untrusted certificate the user chose to proceed past, per
    /// browser profile, until the app quits (never written to disk).
    var certificateExceptions: [BrowserProfileID: Set<String>] = [:]
    /// Hosts whose warnings were turned on again, per profile, until a page
    /// of theirs verifies (WebKitEngine+CertificateWarnings.swift).
    var certificateRechecks: [BrowserProfileID: Set<String>] = [:]
    /// Checks a rechecked host's certificate before its page loads (tests
    /// replace it).
    var certificateProbe: @Sendable (URL) async -> CertificateProbeResult = { await CertificateProbeResult.probe($0) }
    /// The newest main-frame load per tab held for that check; only it may
    /// show the interstitial.
    var certificateAdmissions: [BrowserTabID: Int] = [:]
    /// Energy Saver is on (or Low Power Mode while the `energySaver` feature is off, ``EnergyPolicy/pageSaver``),
    /// as of the policy's last change: every open and new tab renders near 60 fps,
    /// the lowest rate WebKit's render-rate feature gives (Chrome's battery saver throttles frame sinks,
    /// chrome/browser/performance_manager/user_tuning/battery_saver_mode_manager.cc). Open tabs follow a change.
    private(set) var energySaver: Bool {
        didSet { if energySaver != oldValue { applyRenderRate(energySaver: energySaver) } }
    }
    /// Follows the app's Energy Saver policy into ``energySaver`` while the engine lives.
    private var energyObservation: MainActorEnergyObservation?
    /// Open tabs, which follow an Energy Saver change.
    private let openTabs = NSHashTable<WebKitTab>.weakObjects()
    /// The highest rate of a window's display (tests replace it).
    var displayFramesPerSecond: (NSWindow) -> Int = { $0.screen?.maximumFramesPerSecond ?? 60 }
    /// Re-showing a live page after a rate change: nil snapshot takes
    /// WebKit's; the clock times its steps (tests replace both).
    var rateReshowSnapshot: (() async -> NSImage?)?
    var rateReshowClock: any Clock<Duration> = ContinuousClock()
    /// A tab the content lifecycle hides is hidden to WebKit (``WebKitPageVisibility``, feature `webkitHiddenTabs`).
    /// Read when each tab is made; the App sets it once, before its first tab.
    public var hidesHiddenTabs = false
    /// HTTP sign-ins the user chose to remember (Keychain; tests inject memory).
    var httpCredentials: any BrowserHTTPCredentialStoring = KeychainHTTPCredentialStore.standard

    /// The remembered-sign-in rules for a profile's tabs.
    func httpSignInMemory(for profile: BrowserProfileID) -> BrowserHTTPSignInMemory {
        BrowserHTTPSignInMemory(store: httpCredentials, index: stores.httpSignIns, offTheRecord: profileStore.isOffTheRecord(profile))
    }

    /// Per-profile site permissions, shared with the Chromium engine.
    public var siteSettings: SiteSettingsRegistry { stores.siteSettings }
    /// Browser passkey authorization (one per app; tests inject a fake).
    public var passkeyAuthorization: WebKitPasskeyAuthorization = .shared
    /// Appended to WebKit's user agent, e.g. "cmux/1.0 Safari/605.1.15".
    public var applicationNameForUserAgent: String?
    /// What modified link clicks do (cmux.json `browser.links.*`). Read on
    /// each click.
    public var linkClicks: BrowserLinkClickMapping = .chrome
    /// The organization's URL blocklist and allowlist (Chrome's `URLBlocklist`
    /// and `URLAllowlist` policies); the App sets it from the managed policy.
    public var urlFilter: BrowserURLFilter = .none
    /// Where its tabs' content-process ends go as stability events; the App sets its reporting one.
    public var rendererStability = RendererStability()
    #if DEBUG || CMUX_BENCH_HOOKS
    /// DEV and bench builds: reports when each new tab's page painted after an input, so its latency slot gets a
    /// presented time. The App sets it once, before the first tab.
    public var pageInputTiming: WebPageInputTiming?
    #endif
    /// Answers every tab's `<input type="file">` (the tab's `runOpenPanelWith`): the App's one
    /// made-ahead panel (`AppServices.openPanel`, passed through `TabContentCache`), which agent
    /// composer pages share, so a browser tab's file input gets the panel made ahead when one is,
    /// and its dead-panel guard.
    public let fileInput: any WebFileInputAnswering
    /// Where its pages' keyed waits (``BrowserPageWaiting``) put their timeouts: the main thread's one
    /// deadline queue.
    let waitDeadlines: AlignedWakeups
    /// The app's main-thread scheduler: its tabs' and downloads' main-thread follow-ups are classed tasks on it.
    let mainWork: MainWorkScheduler
    /// Its tabs' main-thread deadlines (the title flush, the page-base hold), placed on `mainWork`'s wake-up queue.
    let deadlines: MainDeadlineScheduler
    /// App-wide notices for its tabs: one observer per name for every tab (each tab's Web Inspector watch).
    let appEvents: AppEvents
    /// Same-site tabs share a WebContent process above the renderer limit (``WebKitProcessReuse``); nil (the
    /// `webKitSameSiteProcesses` feature off): every tab starts its own.
    let processReuse: WebKitProcessReuse?

    /// An engine over the App's `stores`.
    ///
    /// - Parameters:
    ///   - fileInput: Answers every tab's file input (the App's made-ahead panel; a test passes a stand-in,
    ///     since a test host cannot make an `NSOpenPanel`).
    ///   - stores: The stores both engines share; the App passes its one set, a test ``BrowserSharedStores/inMemory()``.
    ///   - profileStore: The profiles' website data stores; nil builds one over `stores.offTheRecord`.
    ///   - energy: The app's Energy Saver policy (`MainWorkScheduler.energy`), written on the main actor by its one
    ///     writer; the default, fixed off, is for tests and fixtures.
    ///   - waitDeadlines: The main thread's deadline queue (`MainWorkScheduler.wakeUps`, the one the Chromium engine
    ///     has) for the pages' waits; nil (tests, fixtures): a queue of the engine's own over `energy`.
    ///   - deadlines: The app's one `MainDeadline` placer (`AppServices.mainDeadlines`); its `work` is the app's one
    ///     main-thread scheduler, which the tabs' and downloads' main-thread follow-ups are posted on.
    ///   - appEvents: The app's one ``AppEvents`` (`AppServices.appEvents`): its tabs' app-wide notices share its observers.
    ///   - processReuse: Same-site process sharing above the renderer limit; nil: a process per tab.
    public init(
        fileInput: any WebFileInputAnswering,
        stores: BrowserSharedStores,
        profileStore: WebKitProfileStore? = nil,
        faviconLoader: any BrowserFaviconLoading = BrowserFaviconLoader.shared,
        downloadsDirectory: URL = DownloadDestination.defaultDirectory,
        applicationNameForUserAgent: String? = "Version/26.0 Safari/605.1.15",
        energy: EnergyPolicySource = EnergyPolicySource(),
        waitDeadlines: MainWakeUpQueue? = nil,
        deadlines: MainDeadlineScheduler,
        appEvents: AppEvents,
        processReuse: WebKitProcessReuse? = nil
    ) {
        self.fileInput = fileInput
        self.processReuse = processReuse
        mainWork = deadlines.work
        self.deadlines = deadlines
        self.appEvents = appEvents
        self.waitDeadlines = AlignedWakeups(queue: waitDeadlines ?? MainWakeUpQueue(energy: energy))
        self.stores = stores
        self.profileStore = profileStore ?? WebKitProfileStore(offTheRecord: stores.offTheRecord)
        self.faviconLoader = faviconLoader
        self.downloadsDirectory = downloadsDirectory
        self.applicationNameForUserAgent = applicationNameForUserAgent
        energySaver = energy.policy.pageSaver
        energyObservation = MainActorEnergyObservation(energy) { [weak self] policy in self?.energySaver = policy.pageSaver }
    }

    /// An engine on a main-thread scheduler and app notices of its own (tests and fixtures; internal, so the app,
    /// which must pass its one ``MainDeadlineScheduler`` and ``AppEvents``, cannot reach it).
    convenience init(
        fileInput: any WebFileInputAnswering,
        stores: BrowserSharedStores,
        profileStore: WebKitProfileStore? = nil,
        faviconLoader: any BrowserFaviconLoading = BrowserFaviconLoader.shared,
        downloadsDirectory: URL = DownloadDestination.defaultDirectory,
        applicationNameForUserAgent: String? = "Version/26.0 Safari/605.1.15",
        energy: EnergyPolicySource = EnergyPolicySource(),
        waitDeadlines: MainWakeUpQueue? = nil,
        mainWork: MainWorkScheduler = MainWorkScheduler(budget: MainFrameBudget()),
        appEvents: AppEvents = AppEvents(center: .default),
        processReuse: WebKitProcessReuse? = nil
    ) {
        self.init(fileInput: fileInput, stores: stores, profileStore: profileStore, faviconLoader: faviconLoader,
                  downloadsDirectory: downloadsDirectory, applicationNameForUserAgent: applicationNameForUserAgent, energy: energy,
                  waitDeadlines: waitDeadlines, deadlines: MainDeadlineScheduler(work: mainWork), appEvents: appEvents,
                  processReuse: processReuse)
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
        makeTab(unproxied: BrowserTabConfiguration(id: id, profile: profile, initialURL: initialURL, zoom: zoom, origin: .user),
                webViewConfiguration: webViewConfiguration)
    }

    private func makeTab(unproxied configuration: BrowserTabConfiguration, webViewConfiguration: WKWebViewConfiguration?) -> WebKitTab {
        let webConfiguration = webViewConfiguration ?? makeConfiguration(for: configuration.profile)
        prepare(webConfiguration)
        // A page-opened tab is already related to its opener; any other may join a same-site process.
        let site = processReuse?.site(of: configuration.initialURL)
        let anchor = webViewConfiguration == nil
            ? processReuse?.join(webConfiguration, site: site, profile: configuration.profile, among: openTabs.allObjects) : nil
        let tab = WebKitTab(configuration: configuration, webViewConfiguration: webConfiguration, engine: self,
                            openedByPage: webViewConfiguration != nil)
        tab.processSite = site
        tab.processAnchor = anchor
        openTabs.add(tab)
        if let url = configuration.initialURL {
            tab.load(url)
        }
        return tab
    }

    /// Every open tab takes the rate for the new Energy Saver state.
    private func applyRenderRate(energySaver: Bool) {
        for tab in openTabs.allObjects {
            applyRenderRate(fullRate: WebKitRenderRate.prefersFullRate(energySaver: energySaver), to: tab)
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
              // visibility-walk-allow: WebKit reads the rate when this view becomes visible, so the re-show is for exactly what its own view tree draws now
              let window = webView.window, !webView.isHiddenOrHasHiddenAncestor else { return }
        // A display at 60 Hz or less renders the same either way: no re-show.
        let display = displayFramesPerSecond(window)
        guard WebKitRenderRate.framesPerSecond(energySaver: !fullRate, displayMaxFPS: display)
                != WebKitRenderRate.framesPerSecond(energySaver: fullRate, displayMaxFPS: display) else { return }
        let snapshot = rateReshowSnapshot ?? { [weak webView] in try? await webView?.takeSnapshot(configuration: nil) }
        tab.rateReshow = WebKitRenderRate.reshow(webView, replacing: tab.rateReshow, snapshot: snapshot, clock: rateReshowClock,
                                                 setHidden: { [weak tab] in tab?.setReshowing($0) })
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
        // The display's full rate (120 Hz on ProMotion); near 60 fps under
        // Energy Saver. Open tabs follow a later change (applyRenderRate).
        WebKitRenderRate.apply(fullRate: WebKitRenderRate.prefersFullRate(energySaver: energySaver),
                               to: configuration.preferences)
        // Native element fullscreen takes over the display; the pane shim
        // replaces it (PaneFullscreenScript).
        configuration.preferences.isElementFullscreenEnabled = false
        // Private preference: enables "Inspect Element" in the context menu.
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Private preference: a page's video may enter picture-in-picture
        // (`requestPictureInPicture`, the controls' button); off, WebKit
        // refuses it with NotSupportedError.
        // crash-allow: guarded by responds(to:) on the private setter the KVC key resolves to; absent on older WebKit, skipped.
        if configuration.preferences.responds(to: NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")) { // crash-allow: same guard
            configuration.preferences.setValue(true, forKey: "allowsPictureInPictureMediaPlayback")
        }
        // Every tab gets its own controller. A page-opened configuration is a
        // copy of the opener's and would otherwise share its message handlers.
        configuration.userContentController = WKUserContentController()
    }
}
