import AppKit
import WebKit
import CmuxBrowser

/// Hosts the muted YouTube embed for the window's video background.
///
/// Configuration follows the lightweight webview hosts
/// (`AgentSessionWebRendererCoordinator` / `MarkdownWebRenderer`): transparent
/// background, autoplay allowed, no link previews or gestures. The data store
/// is ephemeral so the background player never pollutes the user's browsing
/// profile. Playback failures surface through `onFailure` and the layer
/// degrades to showing nothing — the terminal is never affected.
@MainActor
final class VideoBackgroundWebPlayerView: NSView, VideoBackgroundPlayerView {
    private let webView: VideoBackgroundWebView
    private let bridge: VideoBackgroundWebViewBridge
    private var desiredPaused = false

    init(source: VideoBackgroundSource, onFailure: @escaping @MainActor (String) -> Void) {
        let bridge = VideoBackgroundWebViewBridge(onPlayerError: onFailure)
        self.bridge = bridge

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(bridge, name: VideoBackgroundEmbedPage.messageHandlerName)

        let webView = VideoBackgroundWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = bridge
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.allowsMagnification = false
        #if DEBUG
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif
        // A Safari-compatible identity keeps YouTube from serving a degraded player.
        webView.applyBrowserUserAgentPolicy(for: VideoBackgroundEmbedPage.baseURL)
        self.webView = webView

        super.init(frame: .zero)
        wantsLayer = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let page = VideoBackgroundEmbedPage(source: source)
        webView.loadHTMLString(page.html, baseURL: VideoBackgroundEmbedPage.baseURL)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setPaused(_ paused: Bool) {
        guard desiredPaused != paused else { return }
        desiredPaused = paused
        let script = paused ? VideoBackgroundEmbedPage.pauseScript : VideoBackgroundEmbedPage.resumeScript
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
