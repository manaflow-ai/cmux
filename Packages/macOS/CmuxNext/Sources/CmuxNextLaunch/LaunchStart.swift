public import CmuxNextWakeups

/// The app services' launch starts and the class each runs in (p06-scheduler-049,
/// plans/cmux-next/chrome-parity/p06-scheduler.md, "Startup phases").
///
/// Chrome sorts startup the same way: what the first window paints runs on the UI thread's startup
/// queues at once (content/browser/scheduler/browser_task_queues.h, `kStartup`), and the rest goes
/// through `AfterStartupTaskUtils::PostTask` (chrome/browser/after_startup_task_utils.cc), held
/// until first paint and the visible page load. A ``LaunchStartClass/firstFrame`` start runs in the
/// launch turn. A ``LaunchStartClass/afterReveal`` start is a ``StartupScheduler`` post at
/// ``StartupPriority/afterStartup``: the background class, which the startup phase opens only at
/// the reveal, released once startup completes. So no deferred start runs, or shows as a
/// `launch.startup_task` signpost, before `launch.revealed`.
///
/// Every case states its class and the switch is exhaustive: a new start does not compile until it
/// has one. Every launch call site goes through ``runNow(_:)`` (first frame) or
/// ``run(on:deferring:_:)`` (after the reveal); ``cloud`` is ``CloudStartPost``'s own post.
///
/// ```swift
/// LaunchStart.energy.runNow { services.startEnergy() }
/// LaunchStart.deviceHub.run(on: order.startup, deferring: true) { services.startDeviceHub(settings) }
/// ```
public enum LaunchStart: CaseIterable, Sendable {
    /// The energy monitor and its consumers (WebKit's render rate, KeepAwake, the video wallpaper):
    /// they start from its inputs before any tab exists.
    case energy
    /// The local daemon: its first snapshot is the first frame's content.
    case localDaemon
    /// The window borders' repaint on a change: a change while the first window lays out repaints it.
    case borders
    /// The glass mode the first frame's pages draw with.
    case glass
    /// Chromium's runtime pack check: a restored Chromium tab reads its engine reason.
    case chromiumRuntime
    /// Browser hibernation and the warm sets: every page the restore makes registers with them.
    case hibernation
    /// The bookmark store: the bookmarks bar of a restored page reads it, and a bookmark made while
    /// the app launches is written through it.
    case bookmarks
    /// Page history persistence: the restored pages' visits are recorded.
    case historyPages
    /// The installed-update card in the Feed (`UpdateFeedPosting.follow`); it builds the Feed.
    case updateFeed
    /// Cloud: the session restore, the Feed mirror, the host replica and the machines' connections.
    /// ``CloudStartPost`` posts it under this name: at afterStartup whatever the feature, or right
    /// after the first frame on a visible need (a restored Cloud window).
    case cloud
    /// The device hub: it waits for the Cloud sign-in restore, which its first read starts.
    case deviceHub
    /// Closed-history retention: each daemon prunes its closed workspaces to the settings' limits.
    case historyRetention
    /// The Chromium likelihood hint: the walk of every tab for a Chromium one, and the palette's
    /// Chromium entries.
    case chromiumLikely
    /// The cmux-tui update notices: the handshake follow, its toast and the tailnet address read
    /// (a `cmux host status` run).
    case serverUpdates

    /// When this start runs.
    public var startClass: LaunchStartClass {
        switch self {
        case .energy, .localDaemon, .borders, .glass, .chromiumRuntime, .hibernation, .bookmarks, .historyPages:
            .firstFrame
        case .updateFeed, .cloud, .deviceHub, .historyRetention, .chromiumLikely, .serverUpdates:
            .afterReveal
        }
    }

    /// Its name in the startup records and the `launch.startup_task` signposts.
    public var name: StaticString {
        switch self {
        case .energy: "AppServices.startEnergy"
        case .localDaemon: "Daemon.startLocal"
        case .borders: "AppServices.observeBorders"
        case .glass: "AppServices.observeGlass"
        case .chromiumRuntime: "ChromiumRuntime.start"
        case .hibernation: "AppServices.startHibernation"
        case .bookmarks: "Bookmarks.start"
        case .historyPages: "History.start"
        case .updateFeed: "UpdateFeed.follow"
        case .cloud: "Cloud.start"
        case .deviceHub: "DeviceHub.start"
        case .historyRetention: "History.closedRetention"
        case .chromiumLikely: "ChromiumWarmup.followLikely"
        case .serverUpdates: "ServerUpdates.follow"
        }
    }

    /// Runs this start by its class.
    ///
    /// - Parameters:
    ///   - startup: The launch's scheduler; nil (an `AppServices` a test builds) runs every start now.
    ///   - deferring: Feature `launchStartDeferral`; false runs every start now, where it ran before.
    ///   - work: The start.
    @MainActor
    public func run(on startup: StartupScheduler?, deferring: Bool, _ work: @escaping @MainActor @Sendable () -> Void) {
        guard deferring, let startup, let priority = startClass.priority else { return work() }
        startup.post(priority, name, on: .main, work)
    }

    /// Runs a ``LaunchStartClass/firstFrame`` start in the launch turn. A start of another class is a
    /// programmer error (a Debug assertion) and still runs, as before its class existed.
    ///
    /// - Parameter work: The start.
    @MainActor
    public func runNow(_ work: () -> Void) {
        assert(startClass == .firstFrame, "\(name) is not a first-frame start: run it with run(on:deferring:_:)")
        work()
    }
}

/// When a ``LaunchStart`` runs.
public enum LaunchStartClass: Sendable, Equatable {
    /// In the launch turn, a direct call: the first frame needs it.
    case firstFrame
    /// A ``StartupPriority/afterStartup`` post: the background class, open from the reveal, released
    /// once startup completes.
    case afterReveal

    /// The priority of its post; nil for a start the launch turn calls directly.
    public var priority: StartupPriority? {
        switch self {
        case .firstFrame: nil
        case .afterReveal: .afterStartup
        }
    }
}
