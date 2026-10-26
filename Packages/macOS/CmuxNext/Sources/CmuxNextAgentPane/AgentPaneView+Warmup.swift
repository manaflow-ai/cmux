import AppKit
import CmuxNextPages
import WebKit

/// Starts WebKit for the page host's WebKit pages once the first window frame is committed
/// (cx-z9kz0): WebKit's first-use setup, and the page pool's one-time font listing (R81:
/// registerUserInstalledFonts runs once per pool), then run before an agent page opened after
/// that frame loads. It used to run before NSApplication.run, where it held the main thread
/// 80-350 ms ahead of the first frame. The view is made in the pool and data store of the agent
/// pages' process groups (``WebUIHost/groupedWebKitConfiguration()``), so the first agent page can
/// use its web content process. It does not start once an agent page was made (that page started
/// WebKit) or the launch settled; the empty page goes when the first agent page loaded
/// (``AgentPaneView/pageLoaded()``) or the launch settled (`LaunchSettle`).
///
/// It no longer has the pool prewarm a second, page-less web content process
/// (`-[WKProcessPool _warmInitialProcess]`, cx-z9kz0, #19847). On some Macs
/// the first load that takes that process holds the main thread for about
/// 11 s: WebKit issues its font sandbox extensions to the prewarmed process
/// while that process's network setup is stalled. A standalone WKWebView app
/// on one test Mac (macOS 27.0.1) held 10.99 s with the prewarm and 0.005 s
/// without; another held 0.006 s either way. A DEV build's watchdog killed
/// every launch on the first (the New Tab spare took the process); a Release
/// build froze. The prewarm saved about 65 ms before the first agent page
/// went live on a cold launch (cx-z9kz0).
extension AgentPaneView {
    private static var warmupView: WKWebView?
    /// Set once an agent page was made or the launch settled, so a later start cannot leave
    /// the empty page (and its web content process) alive for the whole session.
    static var warmupNoLongerNeeded = false

    /// - Parameter webUI: The app's page host (`AppServices.webUI`), whose grouped pages it warms.
    public static func startWarmup(webUI: WebUIHost) {
        guard warmupView == nil, !warmupNoLongerNeeded else { return }
        // webview-allow: WebKit warm-up for the agent pages the page host shows in WebKit
        let view = WKWebView(frame: .zero, configuration: webUI.groupedWebKitConfiguration())
        view.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        warmupView = view
    }

    public static func finishWarmup() {
        warmupNoLongerNeeded = true
        warmupView = nil
    }

    /// The page finished loading (``PageWebView/onLoaded``): marks `agent_pane.page_loaded` for
    /// bench-startup.py, and the warm-up page is done: the first agent page has its process now.
    func pageLoaded() {
        AgentPaneLaunchTimings.shared.mark("agent_pane.page_loaded")
        Self.finishWarmup()
    }
}
