public import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextWakeups
public import Foundation
public import Observation
public import WebKit

/// A browser tab backed by one `WKWebView`.
@MainActor
@Observable
public final class WebKitTab: NSObject, BrowserTab, BrowserAgentFileChoosing, BrowserCacheBypassingReload {
    public let id: BrowserTabID
    public let profileID: BrowserProfileID
    public let engineKind: BrowserEngineKind = .webkit
    public let presentation: BrowserPresentation = .inView

    public var state: BrowserTabState { machine.state }
    public private(set) var favicon: NSImage?
    public private(set) var pendingPrompts: [BrowserPrompt] = []

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

    private var machine = BrowserTabStateMachine()
    @ObservationIgnored private(set) weak var engine: WebKitEngine?
    /// Permission use and certificate failures of the current document (Page Info).
    @ObservationIgnored public let pageInfoActivity = PageInfoActivity()
    @ObservationIgnored var observations: [NSKeyValueObservation] = []
    /// Title changes reach `machine` at most 4 a second (`TitleCoalescer`), as on Chromium:
    /// a ticking title re-rendered the toolbar and rows and wrote history every frame.
    @ObservationIgnored var titleCoalescer = TitleCoalescer()
    @ObservationIgnored let titleTimer = DemandTimer(owner: "WebKitTab.title")
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
    /// The re-show that applies the last render-rate change, while it runs (WebKitEngine).
    @ObservationIgnored var rateReshow: Task<Void, Never>?
    /// Bounds how long the theme color stands in for a committed document
    /// (`pageDidCommit`). Replaceable, so a test can give it a clock that
    /// does not wait.
    @ObservationIgnored var pageBaseHold = DemandTimer(owner: "browser.pageBase")
    /// The daemon's resolved emulation (`WebKitTab+DeviceEmulation`) and the user agent to restore after it.
    @ObservationIgnored public internal(set) var deviceEmulation: BrowserEmulation?
    @ObservationIgnored var userAgentBeforeEmulation: String?
    /// The system's memory pressure, read when the web content process ends (``BrowserExitRecovery``);
    /// a test gives a fixed level.
    @ObservationIgnored var memoryPressure: () -> MemoryPressureLevel = { KernelMemoryPressureLevel().read() }
    /// The one automatic reload a memory end of the web content process owes (`WebKitTab+Delegates`).
    @ObservationIgnored var exitRecovery = BrowserExitRecovery()

    init(configuration: BrowserTabConfiguration, webViewConfiguration: WKWebViewConfiguration, engine: WebKitEngine,
         openedByPage: Bool = false) {
        self.id = configuration.id
        self.profileID = configuration.profile
        self.engine = engine
        let webView = WebKitWebView(frame: .zero, configuration: webViewConfiguration)
        self.webView = webView
        container = WebKitPageContainer(page: webView)
        super.init()
        inspectorWatch.attach(webView: webView, container: container)

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
        WebKitScrollReportHandler.install(on: self, into: controller)
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

    /// WebKit draws in-view and throttles hidden views itself; a page shown after a memory end
    /// takes its one automatic reload (`exitRecovery`).
    public func setContentVisible(_ visible: Bool) {
        if visible { reloadOwedAfterExit() }
    }

    // MARK: Snapshot, script, find

    public func snapshot() async throws -> CGImage {
        guard !isClosed else { throw BrowserTabError.closed }
        let image = try await webView.takeSnapshot(configuration: nil)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
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
        let selector = NSSelectorFromString("_inspector")
        guard webView.responds(to: selector),
              let inspector = webView.perform(selector)?.takeUnretainedValue() as? NSObject else { return }
        let show = NSSelectorFromString("show")
        if inspector.responds(to: show) {
            inspector.perform(show)
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        agentFiles.withdraw()
        removeStandIn()
        faviconTask?.cancel()
        titleTimer.cancel()
        rateReshow?.cancel()
        pageBaseHold.cancel()
        for prompt in pendingPrompts { prompt.respond(prompt.dismissalResponse) }
        pendingPrompts.removeAll()
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
        for observer in navigationObservers.values { observer(event) }
        if machine.state.faviconURL != previousFavicon {
            faviconURLDidChange()
        }
    }

    /// Applies a page title now, or keeps the latest for the end of the
    /// coalescing interval (`TitleCoalescer`, as `CEFTab.offerTitle`).
    private func offerTitle(_ title: String?) {
        let now = ProcessInfo.processInfo.systemUptime
        switch titleCoalescer.offer(title, now: now) {
        case .apply(let update):
            apply(.titleChanged(update.title))
        case .later(let until):
            titleTimer.scheduleIfIdle(after: .milliseconds(Int64(max(0, until - now) * 1000) + 1)) { @MainActor [weak self] in
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
        Task { [weak self] in
            let image = await loader.favicon(at: url, profile: profile)
            guard let self, self.state.faviconURL == url else { return }
            self.favicon = image
        }
    }

    private func observeWebView() {
        observations = [
            webView.observe(\.url, options: [.new]) { @Sendable [weak self] webView, _ in
                MainDelivery().run { self?.apply(.urlChanged(webView.url)) }
            },
            webView.observe(\.title, options: [.new]) { @Sendable [weak self] webView, _ in
                MainDelivery().run { self?.offerTitle(webView.title) }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { @Sendable [weak self] webView, _ in
                MainDelivery().run { self?.apply(.progress(webView.estimatedProgress)) }
            },
            webView.observe(\.canGoBack, options: [.new]) { @Sendable [weak self] webView, _ in
                MainDelivery().run { self?.syncHistory() }
            },
            webView.observe(\.canGoForward, options: [.new]) { @Sendable [weak self] webView, _ in
                MainDelivery().run { self?.syncHistory() }
            },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { @Sendable [weak self] webView, _ in
                MainDelivery().run { self?.syncSecurity() }
            },
        ]
    }

    func syncHistory() {
        restored.syncAvailability()
        let list = webView.backForwardList
        apply(.historyListed(back: list.backList.suffix(Self.historyListLimit).map(\.url.absoluteString),
                             forward: list.forwardList.prefix(Self.historyListLimit).map(\.url.absoluteString)))
    }

    /// URLs kept on each side of the current entry (the daemon's tab record holds 20).
    static let historyListLimit = 20

    func syncSecurity() {
        guard !isClosed, state.phase == .committed || state.phase == .finished else { return }
        apply(.securityChanged(BrowserTabStateMachine.security(
            for: webView.url, hasOnlySecureContent: webView.hasOnlySecureContent,
            certificateBypassed: engine?.loadedPastCertificateWarning(self) ?? false)))
    }
}
