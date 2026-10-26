public import CmuxNextWakeups

/// Launch work no first frame needs, as ``StartupScheduler`` posts with one service start per post,
/// so no main turn after the first frame runs two of them (p08-startup-017; Chrome's
/// AfterStartupTaskUtils::PostTask, chrome/browser/after_startup_task_utils.cc: every deferred
/// startup task is its own post, released one at a time once startup is complete).
///
/// What the person sees soon after the first frame is afterFirstFrame: SSH (it reconnects the
/// restored machines, whose terminals show), and the New Tab spare's open hooks and target window.
/// The rest is afterStartup, the spare's first load too. The app passes its services' starts
/// (`AppServices+AfterFirstFrame`); tests pass their own and read the scheduler's records.
///
/// ```swift
/// LaunchServicePosts.nonPaint(freeTierAttest: attest, ssh: ssh, serverReach: reach, updater: update)
///     .post(on: startup)
/// ```
@MainActor
public struct LaunchServicePosts {
    /// One post: when it runs, its name in the startup records, and its one service start.
    public struct Post {
        /// When it runs.
        public let priority: StartupPriority
        /// Its name in the startup records and signposts.
        public let name: StaticString
        /// The one service start.
        public let work: @MainActor @Sendable () -> Void
    }

    /// The posts, in post order.
    public let posts: [Post]

    /// The free-tier attest, SSH, server reach and the updater (Sparkle).
    ///
    /// - Parameters:
    ///   - freeTierAttest: Starts the free-tier attest.
    ///   - ssh: Starts SSH: restores the saved machines, reconnects those left connected, and wakes
    ///     them on app activation and system wake.
    ///   - serverReach: Starts the server reach.
    ///   - updater: Starts the updater.
    /// - Returns: The posts, SSH at afterFirstFrame and the rest at afterStartup.
    public static func nonPaint(freeTierAttest: @escaping @MainActor @Sendable () -> Void,
                                ssh: @escaping @MainActor @Sendable () -> Void,
                                serverReach: @escaping @MainActor @Sendable () -> Void,
                                updater: @escaping @MainActor @Sendable () -> Void) -> LaunchServicePosts {
        LaunchServicePosts(posts: [
            Post(priority: .afterFirstFrame, name: "SSH.start", work: ssh),
            Post(priority: .afterStartup, name: "FreeTierAttest.start", work: freeTierAttest),
            Post(priority: .afterStartup, name: "ServerReach.start", work: serverReach),
            Post(priority: .afterStartup, name: "Updater.start", work: updater),
        ])
    }

    /// The warm-ups for later tabs (Chromium, the New Tab spare, page hosts) and the agent tab import.
    ///
    /// - Parameters:
    ///   - chromiumWarmup: Arms Chromium's own launch warm-up (task 018 moves its timers onto the scheduler).
    ///   - spareHooks: The New Tab spare's open hooks and target window, no spare yet
    ///     (`NewTabSparePool.start(holdingWarm:)`).
    ///   - spareWarming: Lets the New Tab spare be made (`NewTabSparePool.startWarming()`).
    ///   - pageHostPool: Starts the page host pool.
    ///   - agentTabImport: Starts the agent tab import.
    /// - Returns: The posts, Chromium and the spare's hooks at afterFirstFrame and the rest at afterStartup.
    public static func laterTabs(chromiumWarmup: @escaping @MainActor @Sendable () -> Void,
                                 spareHooks: @escaping @MainActor @Sendable () -> Void,
                                 spareWarming: @escaping @MainActor @Sendable () -> Void,
                                 pageHostPool: @escaping @MainActor @Sendable () -> Void,
                                 agentTabImport: @escaping @MainActor @Sendable () -> Void) -> LaunchServicePosts {
        LaunchServicePosts(posts: [
            Post(priority: .afterFirstFrame, name: "ChromiumWarmup.start", work: chromiumWarmup),
            Post(priority: .afterFirstFrame, name: "NewTabSpares.hooks", work: spareHooks),
            Post(priority: .afterStartup, name: "NewTabSpares.warm", work: spareWarming),
            Post(priority: .afterStartup, name: "PageHostPool.start", work: pageHostPool),
            Post(priority: .afterStartup, name: "AgentTabImport.start", work: agentTabImport),
        ])
    }

    /// Posts each start on its own, in order, to the main thread.
    ///
    /// - Parameter startup: The launch's scheduler.
    public func post(on startup: StartupScheduler) {
        for entry in posts { startup.post(entry.priority, entry.name, on: .main, entry.work) }
    }
}

/// Where the agent pages' WebKit warm-up (`AgentPageWarmup.start()`) runs: one post named
/// `AgentPane.webKitWarmup` (its StartupScheduler record is the named WKProcessPool turn), decided
/// once the launch's restore finished, when the restored panes exist. It is afterFirstFrame when the
/// front window's focused pane shows an agent chat that opens in WebKit, so that page loads warm;
/// else afterStartup. A launch whose startup completes with no restore (the daemon unavailable, the
/// failsafe) posts it at afterStartup then.
@MainActor
public final class AgentPageWarmupSlot {
    private let startup: StartupScheduler
    private let warm: @MainActor @Sendable () -> Void
    /// The priority it was posted at; nil until then.
    public private(set) var postedPriority: StartupPriority?

    /// - Parameters:
    ///   - startup: The launch's scheduler.
    ///   - warm: The warm-up (the app: `AgentPageWarmup.start()` and its launch mark).
    public init(startup: StartupScheduler, warm: @escaping @MainActor @Sendable () -> Void) {
        self.startup = startup
        self.warm = warm
        startup.whenComplete { [weak self] _ in self?.post(.afterStartup) }
    }

    /// The launch's restore finished.
    ///
    /// - Parameter showsWebKitAgentChat: Whether the front window's focused pane shows an agent chat
    ///   that opens in WebKit.
    public func restored(showsWebKitAgentChat: Bool) {
        post(showsWebKitAgentChat ? .afterFirstFrame : .afterStartup)
    }

    private func post(_ priority: StartupPriority) {
        guard postedPriority == nil else { return }
        postedPriority = priority
        startup.post(priority, "AgentPane.webKitWarmup", on: .main, warm)
    }
}
