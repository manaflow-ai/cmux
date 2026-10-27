/// What the later-tab warm-ups (``LaterTabWarmups``) start: the app's engines (`AppServices`), or the fakes of
/// HomeWebFootprintTests, which record each web object a warm-up makes. The agent tab import and the right
/// sidebar's icons make no web object; they ride the same posts.
@MainActor
public protocol LaterTabWarmupHost: AnyObject, Sendable {
    /// Crash recovery holds browser pages back this launch: Chromium's warm-up does not run.
    var skipsBrowserPagesAtLaunch: Bool { get }
    /// Whether Settings, History or Cloud opens in WebKit now (the page host's engine decision, with no side
    /// effect): only then can the page host pool's spare, a WebKit view, serve an open.
    var pooledPagesOpenInWebKit: Bool { get }
    /// Arms Chromium's launch warm-up; it starts Chromium when the launch will use it (`ChromiumHostLaunchStart`).
    func startChromiumWarmup()
    /// The New Tab preload's open hooks and target window, no page yet.
    func armNewTabPreload()
    /// The agent pages' WebKit warm-up; it makes nothing when agent pages open in Chromium.
    ///
    /// - Returns: The launch mark of what it did (`AgentPageWarmupOutcome.launchMark`); nil when the warm-up
    ///   already marked this launch.
    func warmAgentPages() -> String?
    /// Asks off the main thread whether WebKit's setup answers, for the New Tab preload.
    func probeNewTabPreload()
    /// Lets the New Tab preload make its page in the app's one preload slot.
    func warmNewTabPreload()
    /// The page host pool follows the main windows; it makes no host until a page is likely.
    func followWindowsForPageHosts()
    /// The page host pool builds its spare at the next quiet moment.
    func preloadPageHost()
    /// Starts the agent tab import.
    func startAgentTabImport()
    /// Posts the right sidebar's icon build on the cpu lane.
    func buildRightSidebarIcons()
    /// Records the launch mark `name` for bench-startup.py.
    func markLaunch(_ name: String)
}

/// The later-tab warm-ups over their host: the posts of ``LaunchServicePosts/laterTabs(chromiumWarmup:spareHooks:agentPageWarmup:spareProbe:spareWarming:pageHostPool:agentTabImport:rightSidebarIcons:)``
/// and the gates that keep Home's web objects to the ones the launch can use (plans/cmux-next/chrome-parity/
/// p13-webui.md D1 and D2, HomeWebFootprintTests). Chrome warms only the process the next navigation takes
/// (content/browser/renderer_host/spare_render_process_host_manager_impl.cc): the page host pool builds its
/// WebKit spare at launch only while Settings, History or Cloud open in WebKit.
///
/// ```swift
/// LaterTabWarmups(host: services).posts().post(on: startup)
/// ```
@MainActor
public struct LaterTabWarmups {
    private let host: any LaterTabWarmupHost

    /// - Parameter host: What the warm-ups start; each post holds it weakly.
    public init(host: any LaterTabWarmupHost) {
        self.host = host
    }

    /// The posts, Chromium and the New Tab hooks at afterFirstFrame and the rest at afterStartup.
    public func posts() -> LaunchServicePosts {
        let host = host
        return LaunchServicePosts.laterTabs(
            chromiumWarmup: { [weak host] in if let host, !host.skipsBrowserPagesAtLaunch { host.startChromiumWarmup() } },
            spareHooks: { [weak host] in host?.armNewTabPreload() },
            agentPageWarmup: { [weak host] in if let host, let mark = host.warmAgentPages() { host.markLaunch(mark) } },
            spareProbe: { [weak host] in host?.probeNewTabPreload() },
            spareWarming: { [weak host] in host?.warmNewTabPreload() },
            pageHostPool: { [weak host] in
                guard let host else { return }
                // The pool still follows the windows: a later WebKit open builds its spare (PageHostPool.claim).
                host.followWindowsForPageHosts()
                if host.pooledPagesOpenInWebKit { host.preloadPageHost() }
            },
            agentTabImport: { [weak host] in
                guard let host else { return }
                host.startAgentTabImport()
                host.markLaunch("launch.post_window_warmups")
            },
            rightSidebarIcons: { [weak host] in host?.buildRightSidebarIcons() })
    }
}
