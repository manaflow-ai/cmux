public import AppKit
import CmuxNextDesign
public import WebKit

/// Hosts the React agent pane (`Resources/agent-pane/index.html`, built by
/// `scripts/cmux-next/build-agent-pane-web.sh`) in a WKWebView. The page
/// connects to acpmux itself after the handshake; this view only answers
/// host requests, keeps the page on its source, and applies the theme
/// of the scope it sits in (window, workspace), re-applied whenever that
/// scope repaints.
public final class AgentPaneView: NSView {
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
    private let navigation = AgentPaneNavigation()
    /// The composer's mic; nothing runs until the user starts it.
    let dictation: AgentPaneDictation
    private var crashReloads = AgentPaneCrashReloads()
    /// Shown instead of reloading once the page keeps crashing.
    private var crashNotice: NSView?

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
    public init?(model: AgentPaneModel, source: AgentPaneSource? = nil, renderRate: AgentPaneRenderRate = .capped) {
        guard let source = source ?? Self.bundledPage.map({ AgentPaneSource.bundled($0) }) else { return nil }
        self.model = model
        self.source = source
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        self.renderRate = renderRate
        if renderRate != .capped {
            configuration.preferences.setWebKitFeature(Self.near60FPSFeature, enabled: false)
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        dictation = AgentPaneDictation { [weak webView] script in webView?.evaluateJavaScript(script, completionHandler: nil) }
        super.init(frame: .zero)
        configuration.userContentController.addScriptMessageHandler(
            AgentPaneBridge(view: self), contentWorld: .page, name: AgentPaneRequest.handlerName
        )
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
        if renderRate == .adaptive {
            model.onFramePacing = { [weak self] intervals in self?.recordFramePacing(intervals) }
        }
        model.onDictation = { [weak self] command in self?.dictation.handle(command) }
        navigation.view = self
        webView.navigationDelegate = navigation
        addSubview(webView)
        source.load(into: webView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func layout() {
        super.layout()
        webView.frame = bounds
    }

    /// WebKit's feature that renders a page at the display-rate divisor
    /// nearest 60 fps.
    static let near60FPSFeature = "PreferPageRenderingUpdatesNear60FPSEnabled"

    public let renderRate: AgentPaneRenderRate
    private var framePacing = AgentPaneFramePacing()
    /// The display's refresh rate when the pane has no window screen to ask
    /// (tests set it).
    var displayFramesPerSecond: () -> Int = { NSScreen.main?.maximumFramesPerSecond ?? 60 }

    /// An adaptive pane's settled scroll: picks the rate for the next one.
    func recordFramePacing(_ intervals: [Double], at now: Date = Date()) {
        let fps = window?.screen?.maximumFramesPerSecond ?? displayFramesPerSecond()
        guard renderRate == .adaptive, fps > 0 else { return }
        let full = framePacing.record(intervals: intervals, displayInterval: 1000 / Double(fps), at: now)
        if full != rendersAtFullRate { rendersAtFullRate = full }
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
    /// Waits out the re-apply's steps (tests set it).
    // wakeup-allow: one-shot steps of a render-rate change (33 ms hidden, 50 ms covered), injected for tests
    var pause: (Duration) async -> Void = { try? await Task.sleep(for: $0) }

    /// WebKit reads the rate only when the page's visibility changes, so the
    /// web view is hidden for a moment and shown again. A snapshot of the
    /// page covers it meanwhile; the adaptive rate changes only after a
    /// scroll settles, so the snapshot matches what is on screen. Without a
    /// snapshot the rate waits for the next visibility change instead of
    /// blinking the page.
    private func reapplyRenderRate() {
        let previous = rateReapply
        rateReapply = Task { [weak self] in
            await previous?.value
            guard let self, let image = await self.snapshotPage() else { return }
            let cover = NSImageView(frame: self.webView.frame)
            cover.image = image
            cover.imageScaling = .scaleAxesIndependently
            cover.autoresizingMask = [.width, .height]
            self.addSubview(cover, positioned: .above, relativeTo: self.webView)
            let focused = (self.window?.firstResponder as? NSView)?.isDescendant(of: self.webView) == true
            self.webView.isHidden = true
            // Hiding hands keyboard focus to the next key view; take it back
            // unless the user moved it meanwhile.
            let handedTo = self.window?.firstResponder
            await self.pause(.milliseconds(33))
            self.webView.isHidden = false
            if focused, let window = self.window, window.firstResponder === handedTo {
                window.makeFirstResponder(self.webView)
            }
            // The shown page paints its first frame under the cover.
            await self.pause(.milliseconds(50))
            cover.removeFromSuperview()
        }
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
        webView.evaluateJavaScript("window.cmuxAcpmuxBridge?.command?.(\"searchChats\");", completionHandler: nil)
    }

    /// Opens the frontend's Continue in… chooser. The chooser owns target
    /// selection and preparation; native actions do not create a second
    /// handoff pipeline.
    public func showContinueIn() {
        evaluateScript("window.cmuxAcpmuxBridge?.command?.(\"continueIn\");")
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
        dictation.close()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: AgentPaneRequest.handlerName, contentWorld: .page)
        webView.navigationDelegate = nil
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

    /// Reloads the page after its web content process crashed, unless it
    /// keeps crashing; then the pane says so and waits for the user.
    func webContentProcessDidTerminate() {
        // The composer that held the session's words is gone.
        dictation.handle(.cancel)
        if crashReloads.shouldReload(at: .now) {
            source.load(into: webView)
        } else {
            showCrashNotice()
        }
    }

    private func showCrashNotice() {
        guard crashNotice == nil else { return }
        let message = NSTextField(wrappingLabelWithString: Self.crashedMessage)
        message.alignment = .center
        let reload = NSButton(title: Self.reloadTitle, target: self, action: #selector(reloadAfterCrashes))
        let notice = NSStackView(views: [message, reload])
        notice.orientation = .vertical
        notice.spacing = 12
        notice.translatesAutoresizingMaskIntoConstraints = false
        addSubview(notice)
        let inset = notice.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48)
        // A pane narrower than the inset clips the notice instead of
        // breaking the layout.
        inset.priority = .defaultHigh
        NSLayoutConstraint.activate([
            notice.centerXAnchor.constraint(equalTo: centerXAnchor),
            notice.centerYAnchor.constraint(equalTo: centerYAnchor),
            inset,
        ])
        crashNotice = notice
        themeCrashNotice(themeTokens)
    }

    /// The notice sits on the pane's background, so it takes the pane's
    /// theme rather than the system appearance.
    private func themeCrashNotice(_ tokens: ThemeTokens) {
        guard let notice = crashNotice else { return }
        notice.appearance = NSAppearance(named: tokens.isDark ? .darkAqua : .aqua)
        for case let label as NSTextField in notice.subviews {
            label.textColor = tokens.textSecondary.nsColor
        }
    }

    @objc private func reloadAfterCrashes() {
        crashNotice?.removeFromSuperview()
        crashNotice = nil
        crashReloads = AgentPaneCrashReloads()
        source.load(into: webView)
    }

    /// Runs a script in the page (tests record them).
    lazy var evaluateScript: (String) -> Void = { [weak self] script in
        self?.webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Pushes ``customization`` to the page, even an empty one (it clears
    /// what removed files left behind).
    func applyCustomization() {
        for script in customization.scripts() {
            evaluateScript(script)
        }
    }

    /// Re-pushes a non-empty ``customization`` to a page that may not have
    /// had its bridge yet (a load finishing, the page asking for the
    /// handshake once its bridge exists).
    func replayCustomization() {
        guard !customization.isEmpty else { return }
        applyCustomization()
    }

    /// Pushes this view's scope tokens to the page (and to the area WebKit
    /// shows before the page paints).
    func applyTheme() {
        let tokens = themeTokens
        webView.underPageBackgroundColor = AgentPaneTheme.underPageColor(tokens).nsColor
        themeCrashNotice(tokens)
        guard let script = AgentPaneTheme.script(tokens) else { return }
        evaluateScript(script)
    }
}
