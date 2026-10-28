public import CmuxNextWakeups

/// Launch work no first frame needs, as ``StartupScheduler`` posts with one service start per post,
/// so no main turn after the first frame runs two of them (Chrome's
/// AfterStartupTaskUtils::PostTask, chrome/browser/after_startup_task_utils.cc: every deferred
/// startup task is its own post, released one at a time once startup is complete).
///
/// What the person sees soon after the first frame is afterFirstFrame: SSH (it reconnects the
/// restored machines, whose terminals show), and the New Tab spare's open hooks and target window.
/// The rest is afterStartup, the spare's WebKit probe and first load and the agent pages' WebKit
/// warm-up too. The app passes its services' starts
/// (`AppServices+AfterFirstFrame`); tests pass their own and read the scheduler's records.
///
/// ```swift
/// LaunchServicePosts.nonPaint(freeTierAttest: attest, ssh: ssh, serverReach: reach, updater: update,
///                             emptyWorkspaceRepair: repair)
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

    /// The free-tier attest, SSH, server reach, the updater (Sparkle) and the empty-workspace repair.
    ///
    /// - Parameters:
    ///   - freeTierAttest: Starts the free-tier attest.
    ///   - ssh: Starts SSH: restores the saved machines, reconnects those left connected, and wakes
    ///     them on app activation and system wake.
    ///   - serverReach: Starts the server reach.
    ///   - updater: Starts the updater.
    ///   - emptyWorkspaceRepair: Builds the empty-workspace repair, which starts its store observation; a
    ///     window's content builds it before its frame, so this one matters on a launch with no window.
    /// - Returns: The posts, SSH at afterFirstFrame and the rest at afterStartup.
    public static func nonPaint(freeTierAttest: @escaping @MainActor @Sendable () -> Void,
                                ssh: @escaping @MainActor @Sendable () -> Void,
                                serverReach: @escaping @MainActor @Sendable () -> Void,
                                updater: @escaping @MainActor @Sendable () -> Void,
                                emptyWorkspaceRepair: @escaping @MainActor @Sendable () -> Void) -> LaunchServicePosts {
        LaunchServicePosts(posts: [
            Post(priority: .afterFirstFrame, name: "SSH.start", work: ssh),
            Post(priority: .afterStartup, name: "FreeTierAttest.start", work: freeTierAttest),
            Post(priority: .afterStartup, name: "ServerReach.start", work: serverReach),
            Post(priority: .afterStartup, name: "Updater.start", work: updater),
            Post(priority: .afterStartup, name: "EmptyWorkspaceRepair.observe", work: emptyWorkspaceRepair),
        ])
    }

    /// The warm-ups for later tabs (Chromium, WebKit for agent pages, the New Tab spare, page preloads), the
    /// agent tab import and the right sidebar's icons.
    ///
    /// No post here makes a `WKWebView` or a `WKProcessPool` before startup completes:
    /// before completion the only WebKit views are those of the agent tabs the launch shows, each made in
    /// its own afterFirstFrame post once its picture drew (``LaunchViewQueue``). The agent pages' warm-up
    /// and the New Tab spare's WebKit probe and first page are afterStartup.
    ///
    /// - Parameters:
    ///   - chromiumWarmup: Arms Chromium's own launch warm-up (task 018 moves its timers onto the scheduler).
    ///   - spareHooks: The New Tab spare's open hooks and target window, no spare yet
    ///     (`NewTabPreload.start(holdingWarm:)`).
    ///   - agentPageWarmup: The agent pages' WebKit warm-up (`AgentPageWarmup.start(webUI:)`); it makes
    ///     nothing once a shown agent tab made its view, or when agent pages open in Chromium.
    ///   - spareProbe: Asks off the main thread whether WebKit's setup answers (`NewTabPreload.prewarm()`).
    ///   - spareWarming: Lets the New Tab spare be made (`NewTabPreload.startWarming()`).
    ///   - pagePreload: Lets Settings, History and Cloud preload through the preload slot (`PagePreloads.start()`).
    ///   - agentTabImport: Starts the agent tab import.
    ///   - rightSidebarIcons: Posts the right sidebar's icon build on the cpu lane (a panel built first posted it).
    /// - Returns: The posts, Chromium and the spare's hooks at afterFirstFrame and the rest at afterStartup.
    public static func laterTabs(chromiumWarmup: @escaping @MainActor @Sendable () -> Void,
                                 spareHooks: @escaping @MainActor @Sendable () -> Void,
                                 agentPageWarmup: @escaping @MainActor @Sendable () -> Void,
                                 spareProbe: @escaping @MainActor @Sendable () -> Void,
                                 spareWarming: @escaping @MainActor @Sendable () -> Void,
                                 pagePreload: @escaping @MainActor @Sendable () -> Void,
                                 agentTabImport: @escaping @MainActor @Sendable () -> Void,
                                 rightSidebarIcons: @escaping @MainActor @Sendable () -> Void) -> LaunchServicePosts {
        LaunchServicePosts(posts: [
            Post(priority: .afterFirstFrame, name: "ChromiumWarmup.start", work: chromiumWarmup),
            Post(priority: .afterFirstFrame, name: "NewTabSpares.hooks", work: spareHooks),
            Post(priority: .afterStartup, name: "AgentPane.webKitWarmup", work: agentPageWarmup),
            Post(priority: .afterStartup, name: "NewTabSpares.probe", work: spareProbe),
            Post(priority: .afterStartup, name: "NewTabSpares.warm", work: spareWarming),
            Post(priority: .afterStartup, name: "PagePreload.start", work: pagePreload),
            Post(priority: .afterStartup, name: "AgentTabImport.start", work: agentTabImport),
            Post(priority: .afterStartup, name: "RightSidebar.prewarm", work: rightSidebarIcons),
        ])
    }

    /// The platform services (plans/cmux-next/startup-DESIGN.md section 3): nothing on the
    /// first frame or the restore reads them. The updater's settings follow is not here: it applies before
    /// `Updater.start` (`nonPaint`), so the launch runs it inline. The system-wide hot keys and the window style follows are afterFirstFrame, so a
    /// hot key works within a second of launch; the rest is afterStartup. The Apple-event URL handler and
    /// the sign-in handler stay inline (critical): a launch by a URL or a sign-in delivers its event right
    /// after `applicationDidFinishLaunching`.
    ///
    /// - Parameters:
    ///   - globalHotKeys: Registers the system-wide hot keys; nil for an agent- or bench-launched build,
    ///     which never takes them from the person's app (no post).
    ///   - borders: Follows the window border style.
    ///   - glass: Follows the glass mode (the launch sets its first value inline, so the first frame draws it).
    ///   - keepAwake: Starts the keep-awake power assertion follow.
    ///   - mobile: Follows phone access (its listener).
    ///   - notifications: Follows the notification settings (the launch sets the first ones and the Chief pet inline).
    ///   - macScreenSettings: Follows the Share This Mac settings.
    ///   - deviceHub: Starts the device hub.
    ///   - computerUseHelper: Follows the Computer Use helper process setting.
    ///   - hibernationMeasurements: Starts the hibernation's footprint samples and occluded-window checker (the
    ///     hibernation itself starts inline, before the restore mounts a page).
    ///   - apps: Starts the app catalog (an App Store request before it waits).
    ///   - macScreen: Resumes Share This Mac (permissions, shortcut tap, saved device names).
    ///   - updateFeed: Follows the update feed posts.
    /// - Returns: The posts, the hot keys, borders and glass at afterFirstFrame and the rest at afterStartup.
    public static func platform(globalHotKeys: (@MainActor @Sendable () -> Void)?,
                                borders: @escaping @MainActor @Sendable () -> Void,
                                glass: @escaping @MainActor @Sendable () -> Void,
                                keepAwake: @escaping @MainActor @Sendable () -> Void,
                                mobile: @escaping @MainActor @Sendable () -> Void,
                                notifications: @escaping @MainActor @Sendable () -> Void,
                                macScreenSettings: @escaping @MainActor @Sendable () -> Void,
                                deviceHub: @escaping @MainActor @Sendable () -> Void,
                                computerUseHelper: @escaping @MainActor @Sendable () -> Void,
                                hibernationMeasurements: @escaping @MainActor @Sendable () -> Void,
                                apps: @escaping @MainActor @Sendable () -> Void,
                                macScreen: @escaping @MainActor @Sendable () -> Void,
                                updateFeed: @escaping @MainActor @Sendable () -> Void) -> LaunchServicePosts {
        let hotKeys = globalHotKeys.map { [Post(priority: .afterFirstFrame, name: "GlobalHotKeys.start", work: $0)] } ?? []
        return LaunchServicePosts(posts: hotKeys + [
            Post(priority: .afterFirstFrame, name: "Borders.observe", work: borders),
            Post(priority: .afterFirstFrame, name: "Glass.observe", work: glass),
            Post(priority: .afterStartup, name: "KeepAwake.start", work: keepAwake),
            Post(priority: .afterStartup, name: "Mobile.follow", work: mobile),
            Post(priority: .afterStartup, name: "Notifications.follow", work: notifications),
            Post(priority: .afterStartup, name: "MacScreen.followSettings", work: macScreenSettings),
            Post(priority: .afterStartup, name: "DeviceHub.start", work: deviceHub),
            Post(priority: .afterStartup, name: "ComputerUseHelper.follow", work: computerUseHelper),
            Post(priority: .afterStartup, name: "Hibernation.measure", work: hibernationMeasurements),
            Post(priority: .afterStartup, name: "Apps.start", work: apps),
            Post(priority: .afterStartup, name: "MacScreen.activate", work: macScreen),
            Post(priority: .afterStartup, name: "UpdateFeedPosting.follow", work: updateFeed),
        ])
    }

    /// Posts each start on its own, in order, to the main thread.
    ///
    /// - Parameter startup: The launch's scheduler.
    public func post(on startup: StartupScheduler) {
        for entry in posts { startup.post(entry.priority, entry.name, on: .main, entry.work) }
    }
}
