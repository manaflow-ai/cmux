public import AppKit
import CmuxNextDesign
public import CmuxNextPages
import os
public import WebKit

/// Hosts the React agent pane (`Resources/agent-pane/index.html`, built by
/// `scripts/cmux-next/build-agent-pane-web.sh`) in a WKWebView. The page
/// connects to acpmux itself after the handshake; this view only answers
/// host requests, keeps the page on its source, and applies the theme
/// of the scope it sits in (window, workspace), re-applied whenever that
/// scope repaints.
public final class AgentPaneView: NSView {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.webview")
    public let model: AgentPaneModel
    public let webView: WKWebView
    /// Opens a link the user clicked in the transcript. Defaults to the
    /// system handler; the App can route it to a cmux browser tab.
    public var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// The page this pane shows; navigation and the handshake trust only it.
    public let source: AgentPaneSource
    /// The user's `agent-pane` files, pushed to the page when they change,
    /// after each load, and when the page asks for the handshake.
    public var customization = AgentPaneCustomization() {
        didSet {
            if customization != oldValue { applyCustomization() }
        }
    }
    /// The app shortcuts the page shows (``AgentPaneShortcuts``), pushed
    /// when a rebind changes them, after each load, and on the handshake.
    public var shortcuts = AgentPaneShortcuts() {
        didSet {
            if shortcuts != oldValue { applyShortcuts() }
        }
    }
    /// `labs.previewFeatures`: pushed like ``shortcuts``.
    public var previewFeatures = false {
        didSet { if previewFeatures != oldValue { applyPreviewFeatures() } }
    }
    private let navigation = AgentPaneNavigation()
    /// The composer's mic; nothing runs until the user starts it.
    let dictation: AgentPaneDictation
    var crashReloads = PageCrashReloads()
    /// Shown instead of reloading once the page keeps crashing.
    var crashNotice: NSView?
    /// On the shared page host (`cmux-page://cmux.agent/`, the `agent.pageHost` tunable): the page
    /// view and the provider that answers its calls and carries the host's pushes. Nil on the old
    /// host (`cmux-agent://pane`, deleted with P5 of the agent pane move).
    let page: PageWebView?
    let pageEvents: AgentPageProvider?
    /// Whether the page can take typing yet (the key dispatcher queues keys until then).
    public let inputReadiness: PageInputReadiness
    /// Re-pushes the theme when ui.animationSpeed or Reduce Motion changes, so the
    /// page's `--agent-motion-*` fades follow them (AgentPaneTheme.values).
    private var motionObservation: Task<Void, Never>?
    private var reduceMotionObserver: (any NSObjectProtocol)?
    private var reduceMotionOverrideObserver: (any NSObjectProtocol)?

    /// The process pool every agent page shares (R81: fonts are listed once per pool).
    private static let processPool = WKProcessPool()

    /// The bundled page, nil when it is missing (a broken build).
    public static var bundledPage: URL? {
        Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "agent-pane")
    }

    /// Makes a pane and starts loading its page.
    ///
    /// Nil when `source` is nil and the bundled page is missing.
    ///
    /// - Parameters:
    ///   - model: Answers the page's host requests.
    ///   - source: The page to load; nil loads ``bundledPage``.
    ///   - renderRate: How fast the page renders. Adaptive starts at the
    ///     display's full rate and caps it while scrolls miss frames, as they
    ///     do on a loaded machine (#16471).
    ///   - pageHost: Host the page on the shared page host (``PageWebView``) instead of this
    ///     view's own WebKit host. Only a bundled page can move; a dev-server page stays.
    public init?(model: AgentPaneModel, source: AgentPaneSource? = nil, renderRate: AgentPaneRenderRate = .capped,
                 pageHost: Bool = false) {
        guard let source = source ?? Self.bundledPage.map({ AgentPaneSource.bundled($0) }) else { return nil }
        self.model = model
        self.source = source
        self.renderRate = renderRate
        let webView: WKWebView
        if pageHost, case .bundled(let index) = source {
            let provider = AgentPageProvider { [weak model] _ in model }
            guard let page = Self.makePage(root: index.deletingLastPathComponent(), provider: provider, renderRate: renderRate)
            else { return nil }
            self.page = page
            pageEvents = provider
            webView = page.webKitView
            inputReadiness = page.inputReadiness
            dictation = AgentPaneDictation(send: { [weak provider] update in
                if let event = AgentPageEvent.dictation(update) { provider?.publish(event) }
            })
        } else {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            // One process pool for every agent page: a fresh pool per page made WebKit list the
            // user-installed fonts again for each new page (registerUserInstalledFonts, about
            // 25 ms of the 30 ms main-thread page build, R81 trace); a shared pool lists them once.
            configuration.processPool = Self.processPool
            if renderRate != .capped {
                WebKitRenderRate.apply(fullRate: true, to: configuration.preferences)
            }
            source.register(on: configuration)
            // The shared web theme (`window.cmuxTheme`, `--cmux-*`): the page
            // background is the one surface token, or clear over a see-through
            // window (plans/cmux-next/windows.md).
            configuration.userContentController.addUserScript(
                WKUserScript(source: WebTheme.bootstrapScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            inputReadiness = PageInputReadiness(configuration: configuration)
            webView = WKWebView(frame: .zero, configuration: configuration)
            page = nil
            pageEvents = nil
            dictation = AgentPaneDictation(evaluate: { [weak webView] script in webView?.evaluateJavaScript(script, completionHandler: nil) })
        }
        self.webView = webView
        super.init(frame: .zero)
        inputReadiness.attach(webView)
        if let page {
            attachPage(page)
        } else {
            webView.configuration.userContentController.addScriptMessageHandler(
                AgentPaneBridge(view: self), contentWorld: .page, name: AgentPaneRequest.handlerName
            )
        }
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        // The page paints its own background with the theme's opacity;
        // WebKit's opaque backing would hide a translucent window's backdrop.
        // macOS has no public switch, so this uses WebKit's
        // `_setDrawsBackground:` SPI through KVC, checked first (as
        // `WebKitTab` does); without it the pane keeps WebKit's backing.
        if webView.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        #if DEBUG
        // Web Inspector and profiling for the pane (debug.agent_pane).
        webView.isInspectable = true
        #endif
        model.onFramePacing = { [weak self] _ in self?.framePacingSettings() ?? [:] }
        model.onRenderRate = { [weak self] full in
            guard let self, self.renderRate == .adaptive else { return }
            self.rendersAtFullRate = full
        }
        model.onDictation = { [weak self] command in self?.dictation.handle(command) }
        if page == nil {
            navigation.view = self
            webView.navigationDelegate = navigation
            addSubview(webView)
            source.load(into: webView)
        }
        Self.logger.info("agent pane webview loading source=\(Self.sourceDescription(source), privacy: .public) bundled=\(Self.bundledPage != nil, privacy: .public)")
        observeMotion()
    }

    private static func sourceDescription(_ source: AgentPaneSource) -> String {
        switch source {
        case .bundled(let url): return "bundled:\(url.path)"
        case .devServer(let url): return "dev:\(url.absoluteString)"
        }
    }

    private func observeMotion() {
        motionObservation = Task { [weak self] in
            for await _ in Observations({ Motion.speed }) {
                guard let self else { return }
                self.applyTheme()
            }
        }
        // Reduce Motion is not observable through Observation.
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
        reduceMotionOverrideObserver = NotificationCenter.default.addObserver(
            forName: Motion.reduceMotionDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layout() {
        super.layout()
        if let page { page.frame = bounds } else { webView.frame = bounds }
    }

    /// WebKit's feature that renders a page at the display-rate divisor
    /// nearest 60 fps.
    static let near60FPSFeature = WebKitRenderRate.near60FPSFeature

    public let renderRate: AgentPaneRenderRate
    /// The display's refresh rate when the pane has no window screen to ask
    /// (tests set it).
    var displayFramesPerSecond: () -> Int = { NSScreen.main?.maximumFramesPerSecond ?? 60 }

    /// Display information stays native; the page owns adaptive rate policy.
    func framePacingSettings() -> [String: Any] {
        let fps = window?.screen?.maximumFramesPerSecond ?? displayFramesPerSecond()
        return ["adaptive": renderRate == .adaptive && fps > 0,
                "displayInterval": fps > 0 ? 1000 / Double(fps) : 0]
    }

    /// Whether the page renders at the display's full rate. Setting it
    /// changes the live page's preferences and re-shows the page so WebKit
    /// applies them.
    public var rendersAtFullRate: Bool {
        get { webView.configuration.preferences.isWebKitFeatureEnabled(Self.near60FPSFeature) == false }
        set {
            guard newValue != rendersAtFullRate else { return }
            // A WebKit without the feature has no rate to re-apply.
            guard webView.configuration.preferences.setWebKitFeature(Self.near60FPSFeature, enabled: !newValue) else { return }
            reapplyRenderRate()
        }
    }

    /// The re-apply of the last rate change, while it runs.
    private(set) var rateReapply: Task<Void, Never>?
    /// An image of the page as shown; nil skips the re-apply (tests set it).
    lazy var snapshotPage: () async -> NSImage? = { [weak self] in
        try? await self?.webView.takeSnapshot(configuration: nil)
    }
    /// Times the re-apply's steps (tests set it).
    var clock: any Clock<Duration> = ContinuousClock()

    /// WebKit reads the rate only when the page's visibility changes: the
    /// shared re-show hides the web view for a moment under a snapshot of
    /// the page. The adaptive rate changes only after a scroll settles, so
    /// the snapshot matches what is on screen.
    private func reapplyRenderRate() {
        rateReapply = WebKitRenderRate.reshow(webView, replacing: rateReapply, snapshot: snapshotPage, clock: clock)
    }

    /// Toggle Dictation (the shortcut, palette or menu). From a key press,
    /// holding the key past a moment makes it push-to-talk: dictation stops
    /// when the key comes up.
    public func toggleDictation(from event: NSEvent? = NSApp.currentEvent) {
        dictation.toggle(from: event)
    }

    /// Opens the page's "Search chats" palette (Cmd-K, `agentPane.searchChats`);
    /// a second call closes it.
    public func showSearchChats() {
        deliver([.command("searchChats")], scripts: ["window.cmuxAcpmuxBridge?.command?.(\"searchChats\");"])
    }

    /// Opens the frontend's Continue in… chooser. The chooser owns target
    /// selection and preparation; native actions do not create a second
    /// handoff pipeline.
    public func showContinueIn() {
        deliver([.command("continueIn")], scripts: ["window.cmuxAcpmuxBridge?.command?.(\"continueIn\");"])
    }
    /// Palette and page buttons enter the same inline checkpoint review.
    public func showCreateCheckpoint() {
        guard model.checkpointAvailable else { return }
        deliver([.command("createCheckpoint")], scripts: ["window.cmuxAcpmuxBridge?.command?.(\"createCheckpoint\");"])
    }

    /// Runs a grouped-permission action from the app shortcut registry. The
    /// page keeps the decision scoped to its selected session and refuses
    /// stale, collecting, or unavailable groups before sending anything.
    public func runPermissionAction(_ command: String) {
        let allowed = ["permissionAllowOnce", "permissionAllowChat", "permissionDeny", "permissionExpand",
                       "permissionRetry", "permissionRevoke", "permissionRefresh"]
        guard allowed.contains(command) else { return }
        deliver([.command(command)], scripts: ["window.cmuxAcpmuxBridge?.command?.(\"\(command)\");"])
    }

    /// Stops whichever agent pane is dictating, keeping its words, so the
    /// shortcut ends a session started in a tab that is no longer in front.
    /// False when none is.
    @discardableResult
    public static func stopDictation() -> Bool {
        DictationMicrophone.shared.stopListening()
    }

    /// Stops the page (and its WebSocket) for good; call when the tab closes.
    public func close() {
        rateReapply?.cancel()
        motionObservation?.cancel()
        motionObservation = nil
        if let reduceMotionObserver { NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver) }
        if let reduceMotionOverrideObserver { NotificationCenter.default.removeObserver(reduceMotionOverrideObserver) }
        reduceMotionObserver = nil
        reduceMotionOverrideObserver = nil
        dictation.close()
        if let page {
            page.close()
        } else {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: AgentPaneRequest.handlerName, contentWorld: .page)
            webView.navigationDelegate = nil
        }
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        removeFromSuperview()
    }

    /// Another tab took the pane: stop listening, keep the words.
    public override func viewDidHide() {
        super.viewDidHide()
        dictation.handle(.stop)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Its tab or window closed, or it moved out of sight: stop listening, keep the words.
        if window == nil { dictation.handle(.stop) }
        applyTheme()
    }


    /// Runs a script in the page (tests record them).
    lazy var evaluateScript: (String) -> Void = { [weak self] script in
        self?.webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Focus Location Bar on a new tab page: the field takes the keyboard and
    /// selects its text, wherever focus was on the page.
    public func focusLocation() {
        deliver([.focusLocation], scripts: ["window.dispatchEvent(new Event('acpmux-focus-location'))"])
    }

    /// Pushes ``customization`` to the page, even an empty one (it clears
    /// what removed files left behind).
    func applyCustomization() {
        runPageHostRegistry()
        deliver(AgentPageEvent.customization(customization), scripts: customization.scripts())
    }

    /// On the page host, runs the user's `registry.js` as a host script (the old host's scripts
    /// include it): the page's CSP (script-src 'self') refuses a script element the page makes.
    func runPageHostRegistry() {
        guard pageEvents != nil, let script = customization.registryScript else { return }
        evaluateScript(script)
    }

    /// Re-pushes a non-empty ``customization`` to a page that may not have
    /// had its bridge yet (a load finishing, the page asking for the
    /// handshake once its bridge exists).
    func replayCustomization() {
        guard !customization.isEmpty else { return }
        applyCustomization()
    }

    /// The page's surface for overrides (R55): new tab page until a chat starts.
    var surfaceKind: SurfaceKind { model.newTab != nil ? .newTabPage : .agentPane }

    /// Pushes ``shortcuts`` to the page.
    func applyShortcuts() {
        deliver([.shortcuts(shortcuts)], scripts: shortcuts.script().map { [$0] } ?? [])
    }

    /// Pushes this view's scope tokens to the page (and to the area WebKit
    /// shows before the page paints); again when `surfaceKind` changes.
    public func applyTheme() {
        let tokens = themeTokens
        let surface = surfaceKind
        webView.underPageBackgroundColor = AgentPaneTheme.underPageColor(tokens, surface: surface).nsColor
        themeCrashNotice(tokens)
        page?.themeSurface = surface
        deliver(AgentPageEvent.theme(tokens, surface: surface).map { [$0] } ?? [],
                scripts: AgentPaneTheme.script(tokens, surface: surface).map { [$0] } ?? [])
    }

    /// Sends a push to the page: events on the page host, scripts on the old host (only built there).
    func deliver(_ events: [AgentPageEvent], scripts: @autoclosure () -> [String]) {
        if let pageEvents {
            for event in events { pageEvents.publish(event) }
        } else {
            for script in scripts() { evaluateScript(script) }
        }
    }
}
