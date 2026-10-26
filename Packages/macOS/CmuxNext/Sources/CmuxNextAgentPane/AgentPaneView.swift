public import AppKit
import CmuxNextCompat
public import CmuxNextDesign
public import CmuxNextPages
public import CmuxNextSettings
import Observation
import os
public import WebKit

/// Hosts the React agent pane (`Resources/agent-pane/index.html`, built by
/// `scripts/cmux-next/build-agent-pane-web.sh`) on the shared page host (``WebUIHost``, at
/// `cmux-page://cmux.agent/`), in the engine the host picks. The model's
/// ``AgentPaneTransport`` owns the acpmux socket and relays its frames to the
/// page (the page never holds an endpoint or a token); this view answers
/// host requests, keeps the page on its source, and applies the theme
/// of the scope it sits in (window, workspace), re-applied whenever that
/// scope repaints.
public final class AgentPaneView: NSView {
    private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "agent-pane.webview")
    public let model: AgentPaneModel
    public let webView: WKWebView
    /// Opens a link the user clicked in the transcript with the click's `modifiers`: the shared
    /// link rule (``LinkRouter``, `browser.openLinksInCmuxBrowser`; Shift-Command the other target,
    /// Command alone a background tab), from the pane that shows this chat (set in `init`; never
    /// the focused pane).
    public var openURL: (_ url: URL, _ modifiers: NSEvent.ModifierFlags) -> Void = AgentPaneView.routedOpenURL
    static let routedOpenURL: (URL, NSEvent.ModifierFlags) -> Void = {
        LinkRouter.shared.open($0, otherTarget: LinkRouter.isOtherTarget($1), background: LinkRouter.opensInBackground($1))
    }

    public let source: AgentPaneSource
    public var customization = AgentPaneCustomization() { didSet { if customization != oldValue { applyCustomization() } } }
    public var shortcuts = AgentPaneShortcuts() { didSet { if shortcuts != oldValue { applyShortcuts() } } }
    public var previewFeatures = false { didSet { if previewFeatures != oldValue { applyPreviewFeatures() } } }
    /// The `agent.sessionStatus` tunable (Debug Settings), followed live (``AgentPaneSessionStatus``).
    public internal(set) var sessionStatus = AgentPaneTunables.sessionStatus.value { didSet { if sessionStatus != oldValue { AgentPaneSessionStatus.push(to: self) } } }
    /// The newest device chats for the New Tab cards.
    public var deviceChats: [AgentPaneDeviceChat] = [] { didSet { if deviceChats != oldValue { AgentPaneDeviceChat.push(deviceChats, to: self) } } }
    /// The newest recently closed items for the New Tab page's Recently Closed section.
    public var recentlyClosed: AgentPaneClosedList = .empty { didSet { if recentlyClosed != oldValue { AgentPaneClosedItem.push(recentlyClosed, to: self) } } }
    public var editedFiles = AgentPaneEditedFilesSetting.fallback {
        didSet { if editedFiles != oldValue { applyEditedFiles() } }
    }
    let dictation: AgentPaneDictation
    /// Where the Dictation key and Edit ▸ Start Dictation go from this pane (AgentPaneView+DictationKey).
    var dictationKey = AgentPaneDictationKey()
    /// Shown instead of reloading once the page keeps crashing.
    var crashNotice: NSView?
    /// The line that says the chat runs on another cmux install's acpmux (cx-fcaq).
    var otherInstallNotice: ChromeLabel?
    /// "Remote approvals are off" (cx-0q7o), and the restart the chat's machine offers.
    var remoteApprovalsNotice: NSStackView?
    var remoteApprovals: AgentPaneRemoteApprovals?
    /// Owns the inspector export panel and its in-flight state.
    let savePanel = AgentPaneSavePanel()
    /// The app's made-ahead open panel (Add Files, Attach); nil: no file picker (tests).
    private let openPanel: MadeAheadOpenPanel?
    /// The page view the page host opened, and the provider that answers its calls and carries the
    /// host's pushes.
    let page: PageWebView
    let pageEvents: AgentPageProvider
    let warmup: AgentPageWarmup? // the app's agent page WebKit warm-up (init's `warmup`)
    /// Whether the page can take typing yet (the key dispatcher queues keys until then).
    public let inputReadiness: PageInputReadiness
    /// Re-pushes the theme when ui.animationSpeed or Reduce Motion changes, so the
    /// page's `--agent-motion-*` fades follow them (AgentPaneTheme.values).
    private var motionObservation: Task<Void, Never>?, sessionStatusObservation: Task<Void, Never>?, iconFamilyObservation: Task<Void, Never>?
    /// The theme last pushed to the page (I5: a push only when it changed since then; a page load
    /// pushes again with `force`, a page-host replay or a crash forgets it).
    var deliveredThemeEvent: AgentPageEvent?
    /// Pushes every color change of this view's scope to the page, shown or hidden, so a page
    /// shown after a change paints its first frame in the new colors (cx-8w027.12).
    private lazy var themeFollower = ThemeFollower(self) { [weak self] in self?.applyTheme() }
    public var zoom: Double = 1 {
        didSet { guard zoom != oldValue else { return }; applyZoom() }
    }
    private var reduceMotionObserver: MainActorObservation?
    private var reduceMotionOverrideObserver: MainActorObservation?
    /// Hands this pane the person's key presses and clicks that go to it (``AgentPaneUserGestures``),
    /// through one input tap subscription per window, while the pane is in one.
    let gestureRouter: AgentPaneGestureRouter
    var transportPacer: AgentPaneFramePacer?
    /// The message and the selected transcript text the page reported under the pointer for the
    /// next context menu, and where the menu's copies go (tests record them instead).
    var messageMenuTarget: AgentPaneMessageTarget?
    var menuSelection: String?
    /// Pairs a Chromium page's right-click with the page's report for it.
    let menuReports = AgentPaneMenuReportWait()
    var copyText: @MainActor (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    /// Bounded reports from the app-owned webview UI picker.
    /// Receives a bounded element report while the debug UI pointer is active.
    public var uiPointerReport: (@MainActor (JSONValue) -> Void)?
    /// The pane's first frame until its page paints (`AgentPaneView+Loading`).
    public let loadingView = AgentPaneLoadingView()
    public private(set) lazy var redraw = AgentPageRedraw(page: page) // a chat shown again draws first
    public private(set) lazy var topBar = AgentPaneTopBar(pane: self) // the App's omnibar row over a New Tab page (cx-e2aa)
    /// The bundled page, nil when it is missing (a broken build).
    public static var bundledPage: URL? {
        Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "agent-pane")
    }

    /// Makes a pane and starts loading its page.
    ///
    /// Nil when `source` is nil and the bundled page is missing, or when the page host refuses the page.
    ///
    /// - Parameters:
    ///   - model: Answers the page's host requests.
    ///   - source: The page to load; nil loads ``bundledPage``.
    ///   - renderRate: How fast the page renders. Adaptive starts at the
    ///     display's full rate and caps it while scrolls miss frames, as they
    ///     do on a loaded machine (#16471).
    ///   - webUI: The app's page host (`AppServices.webUI`), which opens the page in the engine its
    ///     Chromium host and the page policy pick (tests pass one with a fake Chromium host).
    ///   - openPanel: The app's made-ahead open panel (`AppServices.openPanel`) for Add Files and Attach,
    ///     warmed when the pane reaches a window; nil (tests) shows no file picker and warms none.
    ///   - warmup: The app's agent page WebKit warm-up (`AppServices.agentPageWarmup`), which this page replaces.
    ///   - gestures: The app's gesture router over its input tap: the person's presses in this pane grant
    ///     its page a gesture, and its dictation's hold-to-talk hears the key-up.
    public init?(model: AgentPaneModel, source: AgentPaneSource? = nil, renderRate: AgentPaneRenderRate = .capped,
                 webUI: WebUIHost, openPanel: MadeAheadOpenPanel? = nil, warmup: AgentPageWarmup? = nil, gestures: AgentPaneGestureRouter) {
        guard let source = source ?? Self.bundledPage.map({ AgentPaneSource.bundled($0) }) else { return nil }
        gestureRouter = gestures
        self.openPanel = openPanel
        (self.model, self.source, self.renderRate, self.warmup) = (model, source, renderRate, warmup)
        warmup?.agentPageMade()
        let provider = AgentPageProvider { [weak model] _ in model }
        // Needs you reads the pane's own acpmux (a Chief chat's is the Chief home's), never another.
        provider.pendingAsksSocket = { [weak model] in model?.pendingAsksSocket }
        guard let page = AgentPanePageHost.makePage(root: source.directory, provider: provider, renderRate: renderRate, webUI: webUI)
        else { return nil }
        self.page = page
        pageEvents = provider
        let webView = page.webKitView
        inputReadiness = page.inputReadiness
        dictation = AgentPaneDictation(input: gestures.input, send: { [weak provider] update in
            if let event = AgentPageEvent.dictation(update), provider?.publish(event) == false {
                // The page host reports bounded replay backpressure; reconnecting the acpmux
                // transport resyncs the chat while the provider's replay state restores chrome.
                if let connection = model.transport.connection { model.transport.close(connection: connection) }
            }
        })
        self.webView = webView
        super.init(frame: .zero)
        pageEvents.onUiPointerReport = { [weak self] value in self?.uiPointerReport?(value) }
        openURL = { [weak self] url, modifiers in
            if let self { LinkRouter.shared.open(url, modifiers: modifiers, from: self) } else { Self.routedOpenURL(url, modifiers) }
        }
        inputReadiness.attach(webView)
        attachPage(page)
        applyZoom()
        SystemScrollers.observe(self) { [weak self] _ in self?.applyTheme() } // theme carries data-scrollers
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
        // Web Inspector and profiling for the pane in every build (Inspect Element, Cmd-Opt-I).
        webView.isInspectable = true
        model.onSaveFile = { [weak self] save in try await self?.savePanel.save(save, window: self?.window) ?? false }
        model.onChooseFiles = { [weak self] in
            guard let self, let openPanel else { return [] }
            return await AgentPaneFilePicker(openPanel: openPanel).pick(window: window)
        }
        model.onChooseAttachments = { [weak self] in
            guard let self, let openPanel else { return [] }
            return await AgentPaneFilePicker(openPanel: openPanel).pickAttachments(window: window)
        }
        model.onFramePacing = { [weak self] _ in self?.framePacingSettings() ?? [:] }
        model.onRenderRate = { [weak self] full in
            guard let self, self.renderRate == .adaptive else { return }
            self.rendersAtFullRate = full
        }
        model.onDictation = { [weak self] command in self?.dictation.handle(command) }
        installTransport()
        installContextMenu()
        beginLoadingState()
        Self.logger.info("agent pane webview loading source=\(Self.sourceDescription(source), privacy: .public) bundled=\(Self.bundledPage != nil, privacy: .public)")
        observeMotion()
        observeIconFamily()
        sessionStatusObservation = AgentPaneSessionStatus.follow(self)
    }

    private static func sourceDescription(_ source: AgentPaneSource) -> String {
        switch source {
        case .bundled(let url): return "bundled:\(url.path)"
        }
    }

    private func applyIconFamily() {
        page.setDocumentAttribute("icon-family", AgentPaneTunables.documentAttributes["icon-family"] ?? "")
    }

    private func observeIconFamily() {
        applyIconFamily()
        iconFamilyObservation = Task { [weak self] in
            for await _ in ObservationStream({ IconFamily.tunable.value }) {
                guard let self else { return }
                self.applyIconFamily()
            }
        }
    }

    private func observeMotion() {
        motionObservation = Task { [weak self] in
            for await _ in ObservationStream({ (Motion.speed, Motion.web.isEnabled, Motion.indicators.isEnabled, DesignSettings.shared.statusIndicator.animation, DesignSettings.shared.focusRing.enabled) }) {
                guard let self else { return }
                self.applyTheme()
            }
        }
        // Reduce Motion is not observable through Observation.
        reduceMotionObserver = MainActorObservation(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] in
            self?.applyTheme()
        }
        reduceMotionOverrideObserver = MainActorObservation(Motion.reduceMotionDidChange) { [weak self] in
            self?.applyTheme()
        }
    }

    func applyZoom() {
        // The page host applies the UI scale and the interface scale itself, in either engine.
        page.additionalZoom = zoom
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    nonisolated deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            sessionStatusObservation?.cancel()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layout() {
        super.layout()
        page.frame = topBar.contentFrame(in: bounds)
        if loadingView.superview === self { loadingView.frame = topBar.contentFrame(in: bounds) }
        redraw.laidOut(self)
    }

    public let renderRate: AgentPaneRenderRate
    /// The display's refresh rate when the pane has no window screen to ask
    /// (tests set it).
    var displayFramesPerSecond: () -> Int = { NSScreen.main?.maximumFramesPerSecond ?? 60 }

    /// The re-apply of the last rate change, while it runs.
    var rateReapply: Task<Void, Never>?
    /// An image of the page as shown; nil skips the re-apply (tests set it).
    lazy var snapshotPage: () async -> NSImage? = { [weak self] in
        await self?.pageSnapshot()
    }
    /// Times the re-apply's steps (tests set it).
    var clock: any Clock<Duration> = ContinuousClock()

    /// Toggle Dictation (the shortcut, palette or menu). From a key press,
    /// holding the key past a moment makes it push-to-talk: dictation stops
    /// when the key comes up.
    public func toggleDictation(from event: NSEvent? = NSApp.currentEvent) {
        dictation.toggle(from: event)
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
        iconFamilyObservation?.cancel()
        iconFamilyObservation = nil
        sessionStatusObservation?.cancel()
        reduceMotionObserver = nil
        reduceMotionOverrideObserver = nil
        dictation.close()
        model.shell.terminateAll()
        gestureRouter.detach(self)
        if let connection = model.transport.connection { model.transport.close(connection: connection) }
        model.transport.deliver = nil
        model.transport.onOtherInstall = nil
        model.transport.onRemoteApprovalsOff = nil
        transportPacer?.stop()
        removeContextMenu()
        page.close()
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

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        themeFollower.rebind()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Its tab or window closed, or it moved out of sight: stop listening, keep the words.
        // A frame that grants needs a real gesture in this pane; page script cannot make one.
        if let window { gestureRouter.attach(self, to: window) } else { gestureRouter.detach(self) }
        if window == nil {
            dictation.handle(.stop)
        } else {
            // The composer's + > Attach files or images opens without making a panel (PageOpenPanel).
            openPanel?.warmWhenIdle()
        }
        applyTheme()
    }

    /// Runs a script in the page (tests record them).
    lazy var evaluateScript: (String) -> Void = { [weak self] script in
        self?.page.evaluate(script)
    }

    /// Focus Location Bar on a new tab page: the field takes the keyboard and
    /// selects its text, wherever focus was on the page.
    public func focusLocation() {
        deliver([.focusLocation])
    }

    /// The page's surface for overrides (R55): new tab page until a chat starts.
    var surfaceKind: SurfaceKind { model.newTab != nil ? .newTabPage : .agentPane }

    /// Pushes ``shortcuts`` to the page.
    func applyShortcuts() {
        deliver([.shortcuts(shortcuts)])
    }

    /// Pushes this view's scope tokens to the page (and to the area WebKit
    /// shows before the page paints); again when `surfaceKind` changes. The page gets a push
    /// only when its theme differs from the last one it got; `force` pushes it anyway (a page
    /// that just loaded has none). It runs in this view's scope (`performWithTheme`): whether the
    /// window is see-through here comes from that scope's picture and tint, not the app's (a
    /// workspace's picture at background-opacity 1 painted the chat opaque over it).
    public func applyTheme(force: Bool = false) {
        performWithTheme { applyThemeInScope(force: force) }
    }

    private func applyThemeInScope(force: Bool) {
        themeFollower.rebind()
        let tokens = themeTokens
        let surface = surfaceKind
        webView.underPageBackgroundColor = AgentPaneTheme.underPageColor(tokens, surface: surface).nsColor
        themeCrashNotice(tokens)
        otherInstallNotice?.textColor = tokens.textSecondary.nsColor
        themeLoadingState(tokens)
        page.themeSurface = surface
        guard let event = AgentPageEvent.theme(tokens, surface: surface), force || event != deliveredThemeEvent else { return }
        deliveredThemeEvent = event
        if !pageEvents.publish(event), let connection = model.transport.connection {
            model.transport.close(connection: connection)
        }
    }

    /// Sends pushes to the page; one the provider cannot take closes the transport, whose reconnect
    /// resyncs the chat.
    func deliver(_ events: [AgentPageEvent]) {
        for event in events where !pageEvents.publish(event) {
            if let connection = model.transport.connection { model.transport.close(connection: connection) }
            break
        }
    }
}
