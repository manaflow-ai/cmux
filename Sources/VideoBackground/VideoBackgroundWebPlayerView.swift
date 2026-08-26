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
    /// Internal so tests can drive page events without a live WebKit page.
    let bridge: VideoBackgroundWebViewBridge
    private var desiredPaused = false
    private var desiredMuted: Bool

    /// Runs a script in the embed page. Replaceable so tests can observe
    /// which pause/resume scripts the view issues without a live page.
    var evaluateScript: (String) -> Void

    init(source: VideoBackgroundSource, muted: Bool = true, onFailure: @escaping @MainActor (String) -> Void) {
        let bridge = VideoBackgroundWebViewBridge(onPlayerError: onFailure)
        self.bridge = bridge
        self.desiredMuted = muted

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
        // A Safari-compatible identity keeps YouTube from serving a degraded
        // player. Resolve the policy for YouTube itself: the document origin
        // is cmux's own, but every request that matters goes to YouTube.
        webView.applyBrowserUserAgentPolicy(for: VideoBackgroundEmbedPage.playerHostURL)
        self.webView = webView
        self.evaluateScript = { [weak webView] script in
            webView?.evaluateJavaScript(script, completionHandler: nil)
        }

        super.init(frame: .zero)
        wantsLayer = true
        bridge.onPlayerReady = { [weak self] in self?.applyDesiredState() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        let page = VideoBackgroundEmbedPage(source: source, muted: muted)
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
        applyDesiredPausedState()
    }

    func setMuted(_ muted: Bool) {
        guard desiredMuted != muted else { return }
        desiredMuted = muted
        applyDesiredMutedState()
    }

    /// Replays both pause and mute state. Called when the page loads and when
    /// the player becomes ready: a script evaluated before the document exists
    /// (a window created while occluded, for example) is silently dropped, and
    /// the page would otherwise autoplay with stale `pendingPaused`/`pendingMuted`.
    private func applyDesiredState() {
        applyDesiredPausedState()
        applyDesiredMutedState()
    }

    private func applyDesiredPausedState() {
        evaluateScript(desiredPaused ? VideoBackgroundEmbedPage.pauseScript : VideoBackgroundEmbedPage.resumeScript)
    }

    private func applyDesiredMutedState() {
        evaluateScript(VideoBackgroundEmbedPage.mutedScript(desiredMuted))
    }
}
