import AppKit
public import CmuxNextPages
import WebKit

extension AgentPaneView {
    /// Whether a new agent page shows in WebKit: the page host's engine decision for the agent
    /// page (the options ``AgentPanePageHost`` picks). It is the ``PageEnginePolicy`` decision of
    /// `PageWebView.engineDecision(for:options:hosting:)` with no side effect: it arms no
    /// web-override watch.
    ///
    /// - Parameters:
    ///   - chromiumChat: Whether the agent chat may run in Chromium (`AgentPaneTunables.chromium`).
    ///   - hosting: The app's Chromium page maker (`AppServices.webUI.chromium`); nil for WebKit only.
    /// - Returns: True when a new agent page opens in WebKit.
    public static func newPagesShowInWebKit(chromiumChat: Bool, hosting: (any PageChromiumHosting)?) -> Bool {
        guard chromiumChat, let hosting else { return true }
        let policy = PageEnginePolicy(preference: hosting.preference, chromiumAvailable: hosting.isAvailable,
                                      chromiumServes: hosting.serves(.agent), liveWebOverride: WebDevOverride.current.isActive)
        return policy.decide(for: .agent, options: PageEngineOptions(chromiumAgentChat: chromiumChat)).engine == .webKit
    }

    /// The page finished loading (``PageWebView/onLoaded``): marks `agent_pane.page_loaded` for
    /// bench-startup.py, and the warm-up page is done: the first agent page has its process now.
    func pageLoaded() {
        AgentPaneLaunchTimings.shared.mark("agent_pane.page_loaded")
        warmup?.agentPageLoaded()
    }
}

/// Starts WebKit for the agent pages after the first window frame (cx-z9kz0,
/// p08-startup-017): WebKit's first-use setup, and the page pool's one-time
/// font listing (R81: registerUserInstalledFonts runs once per pool), then run
/// before a later agent page loads. The view is made in the pool and data store
/// of the agent pages' process groups (``WebUIHost/groupedWebKitConfiguration()``),
/// so the first agent page can use its web content process. The app posts
/// ``start(webUI:)`` once the launch's restore finished: at afterFirstFrame when a
/// visible pane shows an agent chat that opens in WebKit
/// (``AgentPaneView/newPagesShowInWebKit(chromiumChat:hosting:)``),
/// else at afterStartup. It used to run before NSApplication.run, where it held
/// the main thread 80-350 ms ahead of the first frame.
///
/// It starts once per run, and never once an agent page was made (that page
/// started WebKit). Its empty page goes when an agent page loaded or the
/// launch settled (`LaunchSettle`). A warm-up that starts after the launch
/// settled keeps WebKit's first-use setup and the pool, and its page goes once
/// its own load ends, so no empty page lives for the session
/// (``AgentPageWarmupPlan``).
///
/// It stays one named main turn (the StartupScheduler records its duration):
/// there is no off-main path. `WKProcessPool`, `WKWebViewConfiguration` and
/// `WKWebView` are main-actor types in the SDK (`WK_SWIFT_UI_ACTOR`), and
/// WebKit's UI-process objects are main-run-loop only, as Chrome's UI-thread
/// objects are (`content/public/browser/browser_thread.h`).
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
///
/// One per app, made by `AppServices` and passed to each `AgentPaneView` and
/// to `LaunchSettle`.
public final class AgentPageWarmup {
    private var plan = AgentPageWarmupPlan()
    private var page: WKWebView?
    /// Ends a page started after the launch settled once its load ends (WebKit holds its navigation
    /// delegate weakly).
    private lazy var loadEnd = AgentPageWarmupLoadEnd(warmup: self)

    public init() {}

    /// Makes the warm-up page: the first `WKProcessPool` and its web content process.
    ///
    /// - Parameter webUI: The app's page host (`AppServices.webUI`), whose grouped pages it warms.
    /// - Returns: True when it made the page; false when an agent page already started WebKit or
    ///   the warm-up already ran this launch.
    @discardableResult
    public func start(webUI: WebUIHost) -> Bool {
        guard let dropsOnLoad = plan.start() else { return false }
        // webview-allow: WebKit warm-up for the agent pages the page host shows in WebKit
        let view = WKWebView(frame: .zero, configuration: webUI.groupedWebKitConfiguration())
        if dropsOnLoad { view.navigationDelegate = loadEnd }
        view.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        page = view
        return true
    }

    /// The launch settled (`LaunchSettle`): the warm-up page goes. A warm-up that has not run yet
    /// (its afterStartup post) still runs; its page goes once its load ends.
    public func settle() {
        if plan.settle() { dropPage() }
    }

    /// An agent page was made: it starts WebKit itself, so no warm-up page is made from now on.
    func agentPageMade() {
        plan.agentPageMade()
    }

    /// An agent page loaded: its process is up, so the warm-up page goes.
    func agentPageLoaded() {
        if plan.agentPageLoaded() { dropPage() }
    }

    /// The warm-up page's load ended (it finished or failed, or its process ended).
    fileprivate func loadEnded() {
        if plan.loadEnded() { dropPage() }
    }

    private func dropPage() {
        page?.navigationDelegate = nil
        page = nil
    }
}

/// When the agent pages' warm-up page may be made and when it goes. It starts once per run and
/// never after an agent page was made. It goes when an agent page loaded or the launch settled;
/// one started after the launch settled goes when its own load ends.
nonisolated struct AgentPageWarmupPlan: Equatable, Sendable {
    /// The warm-up ran this launch.
    private(set) var started = false
    /// An agent page was made (it started WebKit itself).
    private(set) var pageMade = false
    /// The launch settled.
    private(set) var launchSettled = false
    /// The warm-up page exists.
    private(set) var pageAlive = false

    /// The warm-up asks to start.
    ///
    /// - Returns: Nil when it must not start; else whether its page goes once its load ends (true
    ///   when it starts after the launch settled).
    mutating func start() -> Bool? {
        guard !started, !pageMade else { return nil }
        started = true
        pageAlive = true
        return launchSettled
    }

    /// An agent page was made.
    mutating func agentPageMade() {
        pageMade = true
    }

    /// An agent page loaded.
    ///
    /// - Returns: Whether the warm-up page goes now.
    mutating func agentPageLoaded() -> Bool {
        pageMade = true
        return drop()
    }

    /// The launch settled.
    ///
    /// - Returns: Whether the warm-up page goes now.
    mutating func settle() -> Bool {
        launchSettled = true
        return drop()
    }

    /// The warm-up page's load ended.
    ///
    /// - Returns: Whether the page goes now (only after the launch settled).
    mutating func loadEnded() -> Bool {
        launchSettled ? drop() : false
    }

    private mutating func drop() -> Bool {
        defer { pageAlive = false }
        return pageAlive
    }
}

/// Ends a warm-up page started after the launch settled once its load ends.
private final class AgentPageWarmupLoadEnd: NSObject, WKNavigationDelegate {
    private weak var warmup: AgentPageWarmup?

    init(warmup: AgentPageWarmup) {
        self.warmup = warmup
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        warmup?.loadEnded()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: any Error) {
        warmup?.loadEnded()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: any Error) {
        warmup?.loadEnded()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        warmup?.loadEnded()
    }
}
