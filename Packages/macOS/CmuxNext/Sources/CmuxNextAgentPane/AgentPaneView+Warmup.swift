import AppKit
import CmuxNextPages
import WebKit

/// Starts WebKit for the agent pages once the first window frame is committed
/// (cx-z9kz0): its first-use setup and the shared pool's first web content
/// process then run before an agent page opened after that frame loads. It
/// used to run before NSApplication.run, where it held the main thread
/// 80-350 ms ahead of the first frame. It does not start once an agent page
/// was made (that page started WebKit) or the launch settled; the empty page
/// goes once an agent page has loaded or the launch settled (`LaunchSettle`).
///
/// It no longer has the pool prewarm a second, page-less web content process
/// (`-[WKProcessPool _warmInitialProcess]`, cx-z9kz0, #19847). On some Macs
/// the first load that takes that process holds the main thread for about
/// 11 s: WebKit issues its font sandbox extensions to the prewarmed process
/// while that process's network setup is stalled. A standalone WKWebView app
/// on one test Mac (macOS 27.0.1) held 10.99 s with the prewarm and 0.005 s
/// without; another held 0.006 s either way. A DEV build's watchdog killed
/// every launch on the first (the New Tab spare took the process); a Release
/// build froze. The
/// prewarm saved about 65 ms before the first agent page went live on a
/// cold launch (cx-z9kz0). To bring it back, call `_warmInitialProcess` on
/// ``processPool`` after the warmup view's load, once WebKit's stall is
/// understood.
extension AgentPaneView {
    private static var warmupView: WKWebView?
    /// Set once an agent page was made or the launch settled, so a later start cannot leave
    /// the empty page (and its web content process) alive for the whole session.
    static var warmupNoLongerNeeded = false
    /// The in-memory data store every agent page shares. WebKit gives each store its own web
    /// processes, so a fresh store per page could not use the one started here. Storage the
    /// page keys per chat (drafts) stays per chat; the rest is app-wide choices.
    static let sharedDataStore = WKWebsiteDataStore.nonPersistent()

    public static func startWarmup() {
        guard warmupView == nil, !warmupNoLongerNeeded else { return }
        // The bundled agent page normally runs in Chromium. Its unused WebKit fallback needs
        // no renderer until a fallback actually happens; keep the real engine policy's blockers.
        let options = PageEngineOptions(chromiumAgentChat: AgentPaneTunables.chromium.value)
        guard PageWebView.engineDecision(for: .agent, options: options).engine == .webKit else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = sharedDataStore
        configuration.processPool = processPool
        // webview-allow: WebKit warm-up for the old agent host and a page host that falls back to WebKit
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        warmupView = view
    }

    public static func finishWarmup() {
        warmupNoLongerNeeded = true
        warmupView = nil
    }
}
