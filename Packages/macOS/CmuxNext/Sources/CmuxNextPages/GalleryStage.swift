public import AppKit
import CmuxNextCompat
import CmuxNextDesign
public import Foundation
public import WebKit

/// Gallery Stage: a stage of the live gallery (webviews/src/gallery, `bun run gallery:dev`) as a tab of
/// the app, with no separate host or build (Leo, 2026-11-04: "shouldn't the nightly itself or whatever
/// stable app be able to simply do this?"). The tab is in the app's own window, so the stage draws over
/// the person's own backdrop in their theme, accent and scale, and follows them live (`host=app`,
/// webviews/src/gallery/frame/appHost.ts). Move Tab to New Window separates it out; the gallery
/// server's hot reload updates it as the code changes.
///
/// `gallery.openStage` (palette, `cmux action run gallery.openStage --entry agent-pane.composer`;
/// CmuxNextApp's `AppActions` binds it) opens one tab per run: the entry's stage (`variant` picks one),
/// else the gallery's index. The server is web-dev.json's `gallery`, else
/// ``WebDevOverride/defaultGallery``. NIGHTLY, cmux NEXT DEV and Debug only (``WebDevOverride/isEnabled``).
///
/// This keeps which stage each tab shows: a run sets ``next`` around its open, and the tab it opens
/// keeps it. A tab restored at launch has none and shows the gallery's index.
@MainActor
public final class GalleryStageTabs {
    public static let actionID = "gallery.openStage"
    public static let symbol = "square.on.square.dashed"
    /// The URL the tab a run is opening shows.
    public var next: URL?
    private var urls: [String: URL] = [:]

    public init() {}

    /// The tab `key`'s stage view.
    public func view(for key: String) -> NSView? {
        // Only the one tab a run opens takes it, not a restored one built in the same pass.
        if let next {
            urls[key] = next
            self.next = nil
        }
        guard let url = urls[key] ?? WebDevOverride.galleryServer.flatMap({ Self.stageURL(gallery: $0, entry: nil, variant: nil) })
        else { return nil }
        return GalleryStageView(url: url)
    }

    /// Opens one stage tab for a run: the entry's stage, else the gallery's index, through `open` (the
    /// app's page-tab open, false when nothing can hold the tab). The refusal, or nil when it opened.
    public func open(entry: String?, variant: String?, _ open: () -> Bool) -> String? {
        guard let gallery = WebDevOverride.galleryServer, let url = Self.stageURL(gallery: gallery, entry: entry, variant: variant)
        else { return Self.noServer }
        next = url
        defer { next = nil }
        return open() ? nil : Self.noPane
    }

    /// The page a run opens: `gallery/frame.html` for `entry` (and `variant`) with `host=app`, else
    /// the gallery's index; nil when `gallery` is not a loopback server root
    /// (``PageDevServer/loopbackURL(_:)``).
    public nonisolated static func stageURL(gallery: URL, entry: String?, variant: String?) -> URL? {
        guard let root = PageDevServer.loopbackURL(gallery.absoluteString),
              var components = URLComponents(url: root, resolvingAgainstBaseURL: false) else { return nil }
        let base = components.path.hasSuffix("/") ? components.path : components.path + "/"
        let entry = entry?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let variant = variant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !entry.isEmpty else {
            components.path = base + "gallery/"
            components.query = nil
            return components.url
        }
        components.path = base + "gallery/frame.html"
        components.queryItems = [URLQueryItem(name: "entry", value: entry)]
            + (variant.isEmpty ? [] : [URLQueryItem(name: "variant", value: variant)])
            + [URLQueryItem(name: "host", value: "app")]
        return components.url
    }

    /// The tab's title.
    public static var title: String { t("galleryStage.tab.title", "Gallery Stage") }
    /// Why `gallery.openStage` is unavailable: Release and RC builds. Nil when it opens.
    public static var unavailableReason: String? {
        WebDevOverride.isEnabled ? nil : t("galleryStage.refusal.off", "Gallery Stage is only in NIGHTLY and DEV builds.")
    }
    public static var noServer: String { t("galleryStage.refusal.noServer", "The gallery server in web-dev.json is not a local address.") }
    public static var noPane: String { t("galleryStage.refusal.noPane", "This window has no pane for the stage.") }

    private static func t(_ key: StaticString, _ value: String.LocalizationValue) -> String {
        String(localized: key, defaultValue: value, bundle: .module)
    }
}

/// One stage: a clear web view over the window's own backdrop, with the shared web theme (`window.cmuxTheme`,
/// `--cmux-*`) at document start and again on every repaint of this view's scope, and the app's page zoom
/// and scale tokens. It has no host bridge: a stage is fixture data and calls nothing in the app, and
/// it stays on its gallery server's origin.
public final class GalleryStageView: NSView, WKNavigationDelegate {
    public let webView: WKWebView
    private let origin: (scheme: String?, host: String?, port: Int?)
    /// The theme payload the loaded page last got, so a repaint with the same colors is free.
    private var appliedTheme: String?
    private lazy var themeFollower = ThemeFollower(self) { [weak self] in self?.applyTheme() }
    /// Follows `app.uiScale` and the interface scale, which change without a theme repaint.
    private var scaleObservation: Task<Void, Never>?

    public init(url: URL) {
        origin = (url.scheme?.lowercased(), url.host?.lowercased(), url.port)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        WebTheme.installUserScripts(on: configuration.userContentController)
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.theme(.app).applyScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // A gallery stage from a loopback dev server, NIGHTLY, DEV and Debug only (WebDevOverride.isEnabled).
        // webview-allow: renders gallery fixtures with no host bridge, as a browser tab would; dev builds only
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        super.init(frame: .zero)
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        PageWebView.clearBackground(of: webView)
        webView.isInspectable = true
        webView.pageZoom = DesignSettings.shared.uiScale
        addSubview(webView)
        webView.load(URLRequest(url: url))
        // task-owner: one per stage view; ends with the view (weak self) or its deinit
        scaleObservation = Task { [weak self] in
            for await _ in ObservationStream({ (DesignSettings.shared.uiScale, Typography.userScale) }) {
                guard let self else { return }
                self.applyScale()
            }
        }
    }

    // cx-t7hu: not an isolated deinit; its runtime hop traps when released inside an action's task-local scope.
    // The task handle is Sendable and cancels from any thread: a release off main cleans up too.
    nonisolated deinit {
        scaleObservation?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override public func layout() {
        super.layout()
        webView.frame = bounds
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTheme()
    }

    /// Gives the page this view's scope colors and the app's scale when they changed; `reload` after
    /// a navigation, whose new document has only the document-start colors.
    private func applyTheme(reload: Bool = false) {
        themeFollower.rebind()
        if reload { appliedTheme = nil }
        let theme = performWithTheme { Self.theme(themeScope) }
        guard theme.payloadJSON != appliedTheme else { return }
        appliedTheme = theme.payloadJSON
        webView.evaluateJavaScript(theme.applyScript, completionHandler: nil)
        applyScale()
    }

    /// The app's page zoom and its `--cmux-ui-scale` / `--cmux-interface-scale` tokens.
    private func applyScale() {
        webView.pageZoom = DesignSettings.shared.uiScale
        webView.evaluateJavaScript(DesignSettings.shared.interfaceScaleScript(), completionHandler: nil)
    }

    private static func theme(_ scope: ThemeScope) -> WebTheme {
        WebTheme(scope.tokens, reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                 surface: .internalPage)
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        applyTheme(reload: true)
    }

    /// Stays on the gallery server: its frames and modules load, any other navigation is cancelled.
    @objc(webView:decidePolicyForNavigationAction:decisionHandler:)
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let own = url?.scheme?.lowercased() == origin.scheme && url?.host?.lowercased() == origin.host && url?.port == origin.port
        decisionHandler(own || url?.scheme == "about" ? .allow : .cancel)
    }
}
