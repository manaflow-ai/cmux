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
    ///   - rendersAtFullRate: Renders at the display's rate instead of
    ///     WebKit's default, the display-rate divisor nearest 60 fps (80 Hz
    ///     on a 160 Hz display). Off until a frame's paint fits the shorter
    ///     interval: with it on, a fling ran unevenly at 82-99 Hz (#16471).
    public init?(model: AgentPaneModel, source: AgentPaneSource? = nil, rendersAtFullRate: Bool = false) {
        guard let source = source ?? Self.bundledPage.map({ AgentPaneSource.bundled($0) }) else { return nil }
        self.model = model
        self.source = source
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if rendersAtFullRate {
            configuration.preferences.setWebKitFeature("PreferPageRenderingUpdatesNear60FPSEnabled", enabled: false)
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        configuration.userContentController.addScriptMessageHandler(
            AgentPaneBridge(view: self), contentWorld: .page, name: AgentPaneRequest.handlerName
        )
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        #if DEBUG
        // Web Inspector and profiling for the pane (debug.agent_pane).
        webView.isInspectable = true
        #endif
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

    /// Stops the page (and its WebSocket) for good; call when the tab closes.
    public func close() {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: AgentPaneRequest.handlerName, contentWorld: .page)
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        removeFromSuperview()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    /// Reloads the page after its web content process crashed, unless it
    /// keeps crashing; then the pane says so and waits for the user.
    func webContentProcessDidTerminate() {
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

    /// Pushes ``customization`` to the page, even an empty one (it clears
    /// what removed files left behind).
    func applyCustomization() {
        for script in customization.scripts() {
            webView.evaluateJavaScript(script, completionHandler: nil)
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
        webView.underPageBackgroundColor = tokens.contentBackground.nsColor
        themeCrashNotice(tokens)
        guard let script = AgentPaneTheme.script(tokens) else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
