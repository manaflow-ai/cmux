public import AppKit
import CmuxNextDesign
#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextInput
#endif
import CmuxNextWakeups
public import Foundation
public import Observation
public import WebKit

/// A browser tab backed by one `WKWebView`.
@MainActor
@Observable
public final class WebKitTab: NSObject, BrowserTab, BrowserAgentFileChoosing {
    public let id: BrowserTabID
    public let profileID: BrowserProfileID
    public let engineKind: BrowserEngineKind = .webkit
    public let presentation: BrowserPresentation = .inView

    public var state: BrowserTabState { machine.state }
    public private(set) var favicon: NSImage?
    public private(set) var pendingPrompts: [BrowserPrompt] = [] {
        didSet { if pendingPrompts.count > oldValue.count { pageWaiters.notePromptsAdded(pendingPrompts) } }
    }
    /// Keyed waits on this page's phase and prompts (``BrowserPageWaiting``), resumed by the setters of
    /// `machine` and `pendingPrompts`.
    @ObservationIgnored let pageWaiters: PageWaiters

    @ObservationIgnored public weak var delegate: (any BrowserTabDelegate)?
    @ObservationIgnored public weak var keyRouter: (any BrowserKeyRouting)?

    /// The underlying web view. Exposed for WebKit-only features (the
    /// automation executor); engine-neutral callers use `contentView`.
    @ObservationIgnored public let webView: WKWebView
    /// The web view's container (`WebKitPageContainer`): WebKit places an
    /// attached Web Inspector beside the web view inside it.
    public var contentView: NSView { container }
    @ObservationIgnored let container: WebKitPageContainer
    /// A woken tab's last frame over the page until it paints (`WebKitTab+WakeStandIn`).
    @ObservationIgnored var standIn: NSView?
    /// The stand-in's cap (`showStandIn`).
    @ObservationIgnored var standInCap: DemandTimer?
    /// Web Inspector's visibility, for the toolbar's DevTools button.
    @ObservationIgnored public let inspectorWatch = WebKitInspectorWatch()
    /// Files an agent offered this page's next file chooser (`runOpenPanelWith` takes them first).
    @ObservationIgnored public let agentFiles = BrowserAgentFiles()

    private var machine = BrowserTabStateMachine() {
        didSet { if machine.state.phase != oldValue.state.phase { pageWaiters.notePhase(machine.state.phase) } }
    }
    /// The page plays unmuted media (`BrowserAudibleReporting`): `state.media?.isAudible`, kept
    /// apart so its observers wake on the flip only, not on each load tick or title.
    public private(set) var isAudible = false
    @ObservationIgnored private(set) weak var engine: WebKitEngine?
    /// Permission use and certificate failures of the current document (Page Info).
    @ObservationIgnored public let pageInfoActivity = PageInfoActivity()
    @ObservationIgnored var observations: [NSKeyValueObservation] = []
    /// Title changes reach `machine` at most 4 a second (`TitleCoalescer`), as on Chromium:
    /// a ticking title re-rendered the toolbar and rows and wrote history every frame.
    @ObservationIgnored var titleCoalescer = TitleCoalescer()
    /// The flush of a title that waited (`offerTitle`): the tab strip and history show it.
    @ObservationIgnored let titleTimer: MainDeadline
    @ObservationIgnored private var navigationIDs: [ObjectIdentifier: BrowserNavigationID] = [:]
    @ObservationIgnored private var nextNavigation: UInt64 = 0
    /// `observeNavigationEvents` handlers (WebKitTab+Navigations.swift).
    @ObservationIgnored var navigationObservers: [UUID: (BrowserNavigationEvent) -> Void] = [:]
    /// This tab's downloads (`WebKitDownloads`).
    @ObservationIgnored private(set) lazy var downloads = WebKitDownloads(tab: self)
    @ObservationIgnored lazy var restored = WebKitRestoredSessionHost.session(for: self)
    /// Restored or reloaded form submissions ask first (WebKitTab+FormResubmission).
    @ObservationIgnored var formResubmission = WebKitFormResubmission()
    /// Chrome's automatic-downloads rule for this page (WebKitTab+AutomaticDownloads).
    @ObservationIgnored public private(set) lazy var automaticDownloads = makeAutomaticDownloadGate()
    /// The WebContent process the main frame last committed in; nil before then and once it ended (WebKitTab+Processes).
    @ObservationIgnored var committedContentProcess: Int32?
    /// The site of the page that started the current main-frame navigation.
    @ObservationIgnored var navigationSourceSite: String?
    /// The video the main frame's newest navigation asks for, when it may become the player
    /// (`RemoteVideoPage`): a GET that is not a Back or Forward. Only a response for this URL
    /// plays. A POST's video cannot be fetched again, and a traversal must not add a back-list
    /// entry; both keep downloading.
    @ObservationIgnored var mainFramePlayableVideo: URL?
    @ObservationIgnored public let mainFrameStatuses = MainFrameStatuses()
    /// The last right-click's hit (`WebKitContextHit`); the menu takes it.
    @ObservationIgnored var contextHit: (target: BrowserContextMenuTarget, at: ContinuousClock.Instant)?
    @ObservationIgnored private var faviconTask: Task<Void, Never>?
    @ObservationIgnored private var findState = FindState()
    @ObservationIgnored private(set) var isClosed = false
    /// The current document's first content frame (`WebKitFirstPaintHandler`, or its load end with nothing painted).
    @ObservationIgnored let firstContentFrame = BrowserFirstContentFrame()
    /// The re-show that applies the last render-rate change, while it runs (WebKitEngine).
    @ObservationIgnored var rateReshow: Task<Void, Never>?
    /// Bounds how long the theme color stands in for a committed document
    /// (`pageDidCommit`).
    @ObservationIgnored let pageBaseHold: MainDeadline
    /// WebKit draws a background behind the document (`setDrawsPageBackground`): false on a blank or
    /// New Tab page and while a committed document has not painted.
    @ObservationIgnored var drawsPageBackground = true
    /// The app's main-thread scheduler (the engine's): this tab's main-thread follow-ups are classed tasks on it.
    @ObservationIgnored let mainWork: MainWorkScheduler
    /// The tab's node (``adoptNode(_:)``); nil (a page no pane shows: tests, fixtures) counts as visible.
    @ObservationIgnored var visibilityNode: VisibilityNode?
    /// The daemon's resolved emulation (`WebKitTab+DeviceEmulation`) and the user agent to restore after it.
    @ObservationIgnored public internal(set) var deviceEmulation: BrowserEmulation?
    @ObservationIgnored var userAgentBeforeEmulation: String?
    /// The site of the page its process runs (``WebKitProcessReuse``): the first URL's until a document commits, then
    /// the committed one's. Nil with the reuse off, or for a page with no site.
    @ObservationIgnored var processSite: WebKitProcessReuse.Site?
    /// The tab whose process this one joined when it was made (``WebKitProcessReuse``); nil: its own process.
    @ObservationIgnored weak var processAnchor: WebKitTab?

    init(configuration: BrowserTabConfiguration, webViewConfiguration: WKWebViewConfiguration, engine: WebKitEngine,
         openedByPage: Bool = false) {
        self.id = configuration.id
        self.profileID = configuration.profile
        self.engine = engine
        pageWaiters = PageWaiters(deadlines: engine.waitDeadlines)
        mainWork = engine.mainWork
        titleTimer = MainDeadline(owner: "WebKitTab.title", workClass: .visible, scheduler: engine.deadlines)
        pageBaseHold = MainDeadline(owner: "browser.pageBase", workClass: .visible, scheduler: engine.deadlines)
        let webView = WebKitWebView(frame: .zero, configuration: webViewConfiguration)
        self.webView = webView
        container = WebKitPageContainer(page: webView, visibility: WebKitPageVisibility(followsContent: engine.hidesHiddenTabs))
        super.init()
        inspectorWatch.attach(webView: webView, container: container, events: engine.appEvents)
        container.needsPageBackdrop = { [weak self] in self?.samplePageBackdrop() }

        webView.owner = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webView.underPageBackgroundColor = .clear
        // No white before the first page: the pane's theme color shows
        // through until a real page finishes (`PageBackground`). A page a
        // page opened draws WebKit's default at once.
        setDrawsPageBackground(!PageBackground.startsWithTheme(openedByPage: openedByPage))

        let controller = webViewConfiguration.userContentController
        controller.addUserScript(WKUserScript(source: PaneFullscreenScript.source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.add(WeakScriptMessageHandler(self), name: PaneFullscreenScript.messageHandlerName)
        WebKitContextHit.install(self, into: controller)
        WebKitMediaHandler.install(on: self, into: controller)
        WebKitVerificationHandler.install(on: self, into: controller)
        WebKitDesignModeHandler.install(on: self, into: controller)
        WebKitPasskeyInstaller.install(self, into: controller)
        WebKitNotificationBridge.install(on: self, into: controller)
        WebKitFirstPaintHandler.install(on: self, into: controller)
        #if DEBUG || CMUX_BENCH_HOOKS
        engine.pageInputTiming?.install(into: controller)
        #endif
        observeWebView()
        if configuration.zoom != 1 {
            setZoom(configuration.zoom)
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            faviconTask?.cancel()
            rateReshow?.cancel()
            pageBaseHold.cancel()
        }
    }

    // What the page area shows while a document loads is in
    // `WebKitTab+LoadingBackground`.

    // MARK: Navigation commands

    public func load(_ url: URL) {
        automaticDownloads.userGesture()
        startLoad(url)
    }
    public func goBack() { if webView.canGoBack || !restored.step(by: -1) { startGoBack() } }
    public func goForward() { if webView.canGoBack || !restored.step(by: 1) { startGoForward() } }
    public func reload() { startReload() }

    public func stop() {
        webView.stopLoading()
        // Whatever committed keeps the page area from now on, so WebKit draws
        // its background again even if no `didFail` follows the stop.
        pageDidFinish()
        removeStandIn()
        apply(.stopped)
    }

    // MARK: Focus and occlusion

    public func setFocused(_ focused: Bool) {
        guard let window = webView.window else { return }
        if focused {
            window.makeFirstResponder(webView)
        } else if (webView as? WebKitWebView)?.hasKeyboardFocus == true {
            window.makeFirstResponder(nil)
        }
    }

    // MARK: Snapshot, script, find

    public func snapshot() async throws -> CGImage {
        guard !isClosed else { throw BrowserTabError.closed }
        let image = try await webView.takeSnapshot(configuration: nil)
        // SAFETY: a nil rect pointer: AppKit uses the image's own size and writes nothing back.
        guard let cgImage = unsafe image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw BrowserTabError.snapshotUnavailable
        }
        return cgImage
    }

    public func evaluate(_ script: String, world: BrowserScriptWorld, gesture: BrowserScriptGesture) async throws -> BrowserJSValue {
        guard !isClosed else { throw BrowserTabError.closed }
        do {
            // Every public WKWebView evaluation forces a user gesture; cmux's own scripts use the
            // gesture-free one (`WebKitGestureFreeEvaluation`).
            switch gesture {
            case .agent: return BrowserJSValue(foundation: try await webView.evaluateJavaScript(script, in: nil, contentWorld: world.contentWorld))
            case .cmux: return try await WebKitGestureFreeEvaluation(webView: webView).evaluate(script, in: world.contentWorld)
            }
        } catch let error as WKError where error.code == .javaScriptResultTypeIsUnsupported {
            return .null
        } catch let error as WKError where error.code == .javaScriptExceptionOccurred {
            let message = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw BrowserTabError.javaScript(message)
        }
    }

    /// Runs `body` as an async function with named arguments. Safer than
    /// string interpolation for automation input.
    /// - Parameter gesture: Whether the call acts as the person (``BrowserScriptGesture``); no default.
    public func callFunction(
        _ body: String,
        arguments: [String: BrowserJSValue] = [:],
        world: BrowserScriptWorld = .isolated,
        gesture: BrowserScriptGesture
    ) async throws -> BrowserJSValue {
        guard !isClosed else { throw BrowserTabError.closed }
        if gesture == .cmux {
            return try await WebKitGestureFreeEvaluation(webView: webView)
                .callAsync(body, arguments: arguments.mapValues(\.foundationValue), in: world.contentWorld)
        }
        let result = try await webView.callAsyncJavaScript(
            body,
            arguments: arguments.mapValues(\.foundationValue),
            in: nil,
            contentWorld: world.contentWorld
        )
        return BrowserJSValue(foundation: result)
    }

    public func find(_ text: String, direction: BrowserFindDirection, caseSensitive: Bool) async -> BrowserFindResult {
        guard !isClosed, !text.isEmpty else {
            clearFind()
            return .none
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = direction == .backward
        configuration.caseSensitive = caseSensitive
        configuration.wraps = true
        let matchFound = (try? await webView.find(text, configuration: configuration))?.matchFound ?? false

        let count = try? await callFunction(
            FindScripts.countBody,
            arguments: ["needle": .string(text), "caseSensitive": .bool(caseSensitive)],
            gesture: .cmux
        ).numberValue.map { Int($0) }
        return findState.step(query: text, direction: direction, matchFound: matchFound, count: count)
    }

    public func clearFind() {
        findState = FindState()
        WebKitGestureFreeEvaluation(webView: webView).run(FindScripts.clearSelection, in: .page)
    }

    // MARK: Zoom, fullscreen, devtools

    public func setZoom(_ zoom: Double) {
        let clamped = BrowserZoom.clamp(zoom)
        webView.pageZoom = clamped
        apply(.zoomChanged(clamped))
    }

    public func exitContentFullscreen() {
        WebKitGestureFreeEvaluation(webView: webView).run(PaneFullscreenScript.exitScript, in: .page)
    }

    /// Leaves pane fullscreen now: the chrome returns at once, and the page
    /// is told (its shim exits and fires fullscreenchange).
    func leaveContentFullscreen() {
        apply(.contentFullscreenChanged(false))
        exitContentFullscreen()
    }

    /// Opens Web Inspector through WebKit's private `_inspector` object.
    /// There is no public API for this; if WebKit removes it, the user can
    /// still use "Inspect Element" from the context menu.
    public func showDevTools() {
        WebKitInspector(webView: webView).show()
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        visibilityNode?.cancelDeferred(key: Self.progressKey)
        agentFiles.withdraw()
        removeStandIn()
        firstContentFrame.closed()
        faviconTask?.cancel()
        titleTimer.cancel()
        rateReshow?.cancel()
        pageBaseHold.cancel()
        for prompt in pendingPrompts { prompt.respond(prompt.dismissalResponse) }
        pendingPrompts.removeAll()
        pageWaiters.pageEnded()
        observations.removeAll()
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        WebViewRetirement.retire(webView)
        container.removeFromSuperview()
    }

    // MARK: Internals shared with the delegate extension

    func apply(_ event: BrowserNavigationEvent) {
        if case .titleChanged = event {
            // This title replaces one still waiting (the commit's authoritative read), which must not land after it.
            if titleCoalescer.flush(now: ProcessInfo.processInfo.systemUptime) != nil { titleTimer.cancel() }
        } else if let waiting = titleCoalescer.flush(now: ProcessInfo.processInfo.systemUptime) {
            // A title that waited goes before this event, so the state sees them in order.
            titleTimer.cancel()
            machine.apply(.titleChanged(waiting.title))
        }
        let previousFavicon = machine.state.faviconURL
        machine.apply(event)
        let audible = machine.state.media?.isAudible == true
        if audible != isAudible { isAudible = audible }
        container.visibility.playsMedia = machine.state.media?.keepsPageShown(tabMuted: machine.state.isAudioMuted) == true
        for observer in navigationObservers.values { observer(event) }
        if machine.state.faviconURL != previousFavicon {
            faviconURLDidChange()
        }
    }

    /// Applies a page title now, or keeps the latest for the end of the
    /// coalescing interval (`TitleCoalescer`, as `CEFTab.offerTitle`).
    func offerTitle(_ title: String?) {
        let now = ProcessInfo.processInfo.systemUptime
        switch titleCoalescer.offer(title, now: now) {
        case .apply(let update):
            apply(.titleChanged(update.title))
        case .later(let until):
            titleTimer.scheduleIfIdle(after: .milliseconds(Int64(max(0, until - now) * 1000) + 1)) { [weak self] in
                guard let self, !self.isClosed,
                      let update = self.titleCoalescer.fire(now: ProcessInfo.processInfo.systemUptime) else { return }
                self.apply(.titleChanged(update.title))
            }
        }
    }

    func navigationID(for navigation: WKNavigation?, creating: Bool) -> BrowserNavigationID? {
        guard let navigation else {
            return creating ? allocateNavigationID() : state.activeNavigation
        }
        let key = ObjectIdentifier(navigation)
        if let id = navigationIDs[key] { return id }
        guard creating else { return nil }
        let id = allocateNavigationID()
        navigationIDs[key] = id
        return id
    }

    func forgetNavigation(_ navigation: WKNavigation?) {
        guard let navigation else { return }
        navigationIDs[ObjectIdentifier(navigation)] = nil
    }

    func allocateNavigationID() -> BrowserNavigationID {
        nextNavigation += 1
        return BrowserNavigationID(rawValue: nextNavigation)
    }

    func enqueuePrompt(_ kind: BrowserPromptKind, origin: String, completion: @escaping (BrowserPromptResponse) -> Void) {
        guard !isClosed else {
            completion(BrowserPrompt(kind: kind, origin: origin, completion: { _ in }).dismissalResponse)
            return
        }
        var prompt: BrowserPrompt?
        prompt = BrowserPrompt(kind: kind, origin: origin) { [weak self] response in
            self?.pendingPrompts.removeAll { $0 === prompt }
            completion(response)
        }
        if let prompt { pendingPrompts.append(prompt) }
    }

    /// A document committed: its site is now the one this tab's process holds (WebKit swaps the process of a
    /// cross-site navigation), so same-site reuse matches on it.
    func processSiteCommitted() {
        guard let reuse = engine?.processReuse else { return }
        processSite = reuse.site(of: webView.url)
    }

    /// Its WebContent process ended: it holds no site and no longer runs in the process it joined; its next load
    /// starts a process of its own.
    func processSiteEnded() {
        processSite = nil
        processAnchor = nil
    }

    func emit(_ intent: BrowserTabIntent) {
        delegate?.browserTab(self, didRequest: intent)
    }

    var hasDelegate: Bool { delegate != nil }

    func makeChildTab(configuration: WKWebViewConfiguration) -> WebKitTab? {
        engine?.makeWebKitTab(profile: profileID, webViewConfiguration: configuration)
    }

    var downloadsDirectory: URL {
        engine?.downloadsDirectory ?? DownloadDestination.defaultDirectory
    }

    func refreshFavicon() {
        faviconTask?.cancel()
        // main-hop-allow: evaluate is this tab's main-actor async script call (the script runs in the web content process); the task only starts it and applies the URL it answers
        faviconTask = Task { [weak self] in
            guard let self,
                  let value = try? await self.evaluate(FaviconScript.source, world: .isolated, gesture: .cmux),
                  let string = value.stringValue,
                  let url = URL(string: string),
                  !Task.isCancelled else { return }
            self.apply(.faviconChanged(url))
        }
    }

    // MARK: Private

    private func faviconURLDidChange() {
        guard let url = state.faviconURL else {
            favicon = nil
            return
        }
        guard let loader = engine?.faviconLoader else { return }
        let profile = profileID
        // main-hop-allow: the loader is main-actor async (its fetch runs on URLSession); the task only starts it and sets the icon it answers
        Task { [weak self] in
            let image = await loader.favicon(at: url, profile: profile)
            guard let self, self.state.faviconURL == url else { return }
            self.favicon = image
        }
    }
}
