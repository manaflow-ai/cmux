import AppKit
public import CmuxNextPages
public import CmuxNextSignposts
import WebKit

extension AgentPaneView {
    /// Whether a new agent page shows in WebKit: the page host's engine decision for the agent
    /// page (the options ``AgentPanePageHost`` picks). It is the ``PageEnginePolicy`` decision of
    /// `PageWebView.engineDecision(for:options:hosting:)` with no side effect: it arms no
    /// web-override watch.
    ///
    /// - Parameters:
    ///   - chromiumChat: Whether the agent chat may run in Chromium (feature `agentChromium`).
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

/// Starts WebKit for the agent pages after the first window frame (cx-z9kz0):
/// WebKit's first-use setup, and the page pool's one-time
/// font listing (R81: registerUserInstalledFonts runs once per pool), then run
/// before a later agent page loads. The view is made in the pool and data store
/// of the agent pages' process groups (``WebUIHost/groupedWebKitConfiguration()``),
/// so the first agent page can use its web content process. The app posts
/// ``start(webUI:)`` at afterStartup: before startup
/// completes, the only WebKit views are those of the agent tabs the launch
/// shows, each made in its own afterFirstFrame post once its picture drew
/// (`LaunchViewQueue`), and the first of them starts WebKit itself, so the
/// warm-up then makes nothing. It used to run before NSApplication.run, where
/// it held the main thread 80-350 ms ahead of the first frame.
///
/// It makes nothing when new agent pages open in Chromium: the
/// page host's engine decision for the agent page
/// (``AgentPaneView/newPagesShowInWebKit(chromiumChat:hosting:)``) is taken when
/// it runs, so a launch with Chromium as the default makes no `WKWebView`, no
/// `WKProcessPool` and no WebKit process for it. Chrome likewise warms only the
/// process the next navigation will take (`content/browser/renderer_host/
/// spare_render_process_host_manager_impl.cc`, `WarmupSpare`).
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
    private(set) var page: WKWebView?
    /// Hears the page's load end and its content process's end (WebKit holds its navigation delegate weakly):
    /// a page started after the launch settled goes once its load ends.
    private lazy var loadEnd = AgentPageWarmupLoadEnd(warmup: self)
    /// Whether the agent chat may run in Chromium, read at each engine decision.
    private let chromiumChat: @MainActor () -> Bool
    /// Where the page's content-process end goes as a stability event; nil records none.
    private let stability: RendererStability?
    /// The WebContent process the page committed in: grouped pages can run in it too
    /// (``WebUIHost/groupedWebKitConfiguration()``), so its end names it and counts that process once.
    private var committedProcess: Int32?

    /// - Parameters:
    ///   - chromiumChat: Whether the agent chat may run in Chromium (the app passes feature `agentChromium`,
    ///     `AppServices.agentChromiumChat`). Every engine decision of the warm-up (each ``start(webUI:)``) reads this
    ///     one seam.
    ///   - stability: The app's renderer stability events (`AppServices.rendererStability`).
    public init(chromiumChat: @escaping @MainActor () -> Bool, stability: RendererStability? = nil) {
        self.chromiumChat = chromiumChat
        self.stability = stability
    }

    /// Whether a new agent page opens in WebKit now: the decision that lets the warm-up make its page.
    ///
    /// - Parameter webUI: The app's page host (`AppServices.webUI`), whose Chromium page maker decides.
    /// - Returns: ``AgentPaneView/newPagesShowInWebKit(chromiumChat:hosting:)`` with this warm-up's seam.
    private func agentPagesShowInWebKit(webUI: WebUIHost) -> Bool {
        AgentPaneView.newPagesShowInWebKit(chromiumChat: chromiumChat(), hosting: webUI.chromium)
    }

    /// Makes the warm-up page: the first `WKProcessPool` and its web content process.
    ///
    /// - Parameter webUI: The app's page host (`AppServices.webUI`), whose grouped pages it warms
    ///   and whose Chromium page maker decides the agent pages' engine.
    /// - Returns: What it did; its ``AgentPageWarmupOutcome/launchMark`` is the launch mark.
    @discardableResult
    public func start(webUI: WebUIHost) -> AgentPageWarmupOutcome {
        let dropsOnLoad: Bool
        switch plan.start(agentPagesShowInWebKit: agentPagesShowInWebKit(webUI: webUI)) {
        case let .skip(outcome): return outcome
        case let .make(drops): dropsOnLoad = drops
        }
        // webview-allow: WebKit warm-up for the agent pages the page host shows in WebKit
        let view = WKWebView(frame: .zero, configuration: webUI.groupedWebKitConfiguration())
        // Every warm-up page hears its content process's end; only one made after the launch settled goes at its
        // load end (``AgentPageWarmupPlan/loadEnded()`` drops nothing before then).
        view.navigationDelegate = loadEnd
        view.loadHTMLString("<!doctype html><title></title>", baseURL: nil)
        page = view
        return .made
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

    /// The warm-up page committed its document in `process`.
    fileprivate func committed(in process: Int32?) {
        committedProcess = process
        if let process { stability?.webKitContentCommitted(in: process) }
    }

    /// The warm-up page's content process ended: a stability event, then the end of its load.
    fileprivate func contentProcessEnded() {
        stability?.webKitContentEnded(on: .warmup, process: committedProcess)
        committedProcess = nil
        loadEnded()
    }

    private func dropPage() {
        page?.navigationDelegate = nil
        page = nil
        committedProcess = nil
    }
}

/// When the agent pages' warm-up page may be made and when it goes. It starts once per run, only
/// while new agent pages open in WebKit, and never after an agent page was made. It goes when an
/// agent page loaded or the launch settled; one started after the launch settled goes when its own
/// load ends.
nonisolated struct AgentPageWarmupPlan: Equatable, Sendable {
    /// The warm-up ran this launch.
    private(set) var started = false
    /// An agent page was made (it started WebKit itself).
    private(set) var pageMade = false
    /// The launch settled.
    private(set) var launchSettled = false
    /// The warm-up page exists.
    private(set) var pageAlive = false

    /// What a start request does.
    nonisolated enum Start: Equatable, Sendable {
        /// Make the page; `dropsOnLoad` when it goes once its load ends (it starts after the launch settled).
        case make(dropsOnLoad: Bool)
        /// Make nothing, for this reason.
        case skip(AgentPageWarmupOutcome)
    }

    /// The warm-up asks to start.
    ///
    /// - Parameter agentPagesShowInWebKit: Whether a new agent page opens in WebKit now. When it
    ///   opens in Chromium a WebKit page warms nothing it will use, so none is made.
    /// - Returns: Whether it makes its page, and if not, why.
    mutating func start(agentPagesShowInWebKit: Bool) -> Start {
        if started { return .skip(.alreadyRan) }
        if pageMade { return .skip(.agentPageStartedWebKit) }
        if !agentPagesShowInWebKit { return .skip(.agentPagesInChromium) }
        started = true
        pageAlive = true
        return .make(dropsOnLoad: launchSettled)
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

/// Hears a warm-up page's load end and content-process end.
private final class AgentPageWarmupLoadEnd: NSObject, WKNavigationDelegate {
    private weak var warmup: AgentPageWarmup?

    init(warmup: AgentPageWarmup) {
        self.warmup = warmup
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation?) {
        warmup?.committed(in: webView.contentProcessID)
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
        warmup?.contentProcessEnded()
    }
}
