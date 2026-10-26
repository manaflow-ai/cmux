public import CmuxNextWakeups

/// The app services' launch starts that are not their own ``LaunchServicePosts`` post, and the class
/// each runs in (p06-scheduler-049, plans/cmux-next/chrome-parity/p06-scheduler.md, "Startup phases").
///
/// Chrome sorts startup the same way: what the first window needs runs on the UI thread at once
/// (the bootstrap queue, `BrowserTaskQueues::QueueType::kBootstrap` in
/// content/browser/scheduler/browser_task_queues.h), and the rest goes through
/// `AfterStartupTaskUtils::PostTask` (chrome/browser/after_startup_task_utils.cc), held until first
/// paint and the visible page load.
///
/// - A ``LaunchStartClass/firstFrame`` start runs in the launch turn inside its `launch.startup_task`
///   signpost, `priority=launchTurn`, as the watchdog's current task (``runNow(on:_:)``).
/// - A ``LaunchStartClass/afterReveal`` start is a ``StartupScheduler`` post at
///   ``StartupPriority/afterStartup``: the background class, which the startup phase opens only at the
///   reveal, released once startup completes. So none runs, or shows as a `launch.startup_task`
///   signpost, before `launch.revealed`. Cloud is always posted (``CloudStartPost``); the others are
///   posted with feature `launchStartDeferral` and run where they ran before without it.
///
/// A start the launch posts through ``LaunchServicePosts`` (SSH, the updater, the platform services,
/// the service starts, the browser follows) has its class there, as the post's priority. The exhaustive
/// switches make every case here state its class and name; they cannot make a launch call use a case,
/// so a start added to the launch with neither stays unclassified until it gets one. Not starts: the
/// launch's wiring (handlers, binds, menus, window hooks), its startup machinery (the scheduler, the
/// settle references, the watchdog, the control socket's bind) and the reads of the settings and
/// preferences the views made in the launch turn draw with (theme, link and omnibar preferences).
///
/// ```swift
/// LaunchStart.energy.runNow(on: order.startup) { services.startEnergy() }
/// LaunchStart.historyRetention.run(on: order.startup, deferring: true) { retention.start(settings: settings) }
/// ```
public enum LaunchStart: CaseIterable, Sendable {
    /// The energy monitor and its consumers (WebKit's render rate, KeepAwake, the video wallpaper):
    /// they start from its inputs before any tab exists.
    case energy
    /// Debug Settings' overrides (DEV and NIGHTLY), applied before any window lays out.
    case debugSettings
    /// Ghostty's keybinds in the key router: the first key press reads them.
    case ghosttyKeybinds
    /// Ghostty's config file watch: an edit while the first window builds applies to it.
    case ghosttyConfigReload
    /// The terminal key path's input-source switch keys (read off main).
    case inputSources
    /// The managed (MDM) policy the settings and the first window obey.
    case managedPolicy
    /// The settings file's load and watch: every setting the first frame reads.
    case settings
    /// Opt-in hang reports: a hang in the launch is reported.
    case hangReports
    /// The chat settings pushed to the agent daemon: restored agent chats run with them at once.
    case chatSettingsPush
    /// The glass mode the first frame's pages draw with (its follow is the `Glass.observe` post).
    case glass
    /// The notification preferences and the Chief pet that takes arrivals: the restore's first
    /// notifications use them (their settings follow is the `Notifications.follow` post).
    case notificationPreferences
    /// The updater's settings: `Updater.start` (a post) runs on the person's schedule and ring, and the
    /// sidebar's What's New item and tip card follow their switches.
    case updaterSettings
    /// Browser hibernation and the warm sets: every page the restore makes registers with them.
    case hibernation
    /// `energy.saver` into the policy driver, so its first policy follows the setting.
    case energySaver
    /// cmux.json's custom actions: the menus and the palette list them.
    case configActions
    /// The theme catalog the first frame's chrome draws with.
    case themes
    /// `browser.showBookmarksBar` and the bar's icons: a restored page shows its bar or not.
    case bookmarksBar
    /// The daemon's prompts (pairing, trust): the local daemon's first request may ask one.
    case daemonPrompts
    /// The local daemon: its first snapshot is the first frame's content.
    case localDaemon
    /// The administrator's disabled features, applied before any window shows one.
    case featurePolicy
    /// The browser profiles the restored pages open in.
    case browserProfiles
    /// Home's workspace: the restore's first workspace waits for it.
    case homeWorkspace
    /// The mouse's back and forward buttons: input from the first frame on.
    case mouseSideButtons
    /// keybindings.json, the binding table's user layer: the first key press reads it.
    case keybindingsFile
    /// The bookmark store: the file read, the daemon's bookmark events and the import sink. The
    /// bookmarks bar of a restored page reads it, and a bookmark made while the app launches is
    /// written through it.
    case bookmarks
    /// Page history persistence: the restored pages' visits are recorded.
    case historyPages
    /// Chromium's runtime pack check: a restored Chromium tab reads its engine reason.
    case chromiumRuntime
    /// Cloud: the session restore, the Feed mirror, the host replica and the machines' connections.
    /// ``CloudStartPost`` posts it under this name and class, or right after the first frame on a
    /// visible need (a restored Cloud window).
    case cloud
    /// Closed-history retention: each daemon prunes its closed workspaces to the settings' limits.
    /// Without the feature it runs in the `History.startDaemonSync` post, after the first frame.
    case historyRetention
    /// The Chromium likelihood hint: the walk of every tab for a Chromium one, and the palette's
    /// Chromium entries. Without the feature it runs in the `ChromiumWarmup.start` post.
    case chromiumLikely
    /// Bookmark sync: Chromium's bookmark models follow cmux's trees, and the one-time migration of
    /// earlier browser imports into bookmarks. Without the feature it runs after ``bookmarks``.
    case bookmarkSync

    /// When this start runs.
    public var startClass: LaunchStartClass {
        switch self {
        case .energy, .debugSettings, .ghosttyKeybinds, .ghosttyConfigReload, .inputSources, .managedPolicy, .settings,
             .hangReports, .chatSettingsPush, .glass, .notificationPreferences, .updaterSettings, .hibernation, .energySaver,
             .configActions, .themes, .bookmarksBar, .daemonPrompts, .localDaemon, .featurePolicy, .browserProfiles,
             .homeWorkspace, .mouseSideButtons, .keybindingsFile, .bookmarks, .historyPages, .chromiumRuntime:
            .firstFrame
        case .cloud, .historyRetention, .chromiumLikely, .bookmarkSync:
            .afterReveal
        }
    }

    /// Its name in the startup records and the `launch.startup_task` signposts (the critical
    /// allowlist's name where the start has one there).
    public var name: StaticString {
        switch self {
        case .energy: "AppServices.startEnergy"
        case .debugSettings: "DebugSettings.start"
        case .ghosttyKeybinds: "GhosttyKeybindSync.start"
        case .ghosttyConfigReload: "GhosttyConfigLiveReload.start"
        case .inputSources: "InputSources.start"
        case .managedPolicy: "ManagedPolicyBridge.start"
        case .settings: "Settings.start"
        case .hangReports: "HangReports.start"
        case .chatSettingsPush: "ChatSettingsPush.start"
        case .glass: "Glass.seed"
        case .notificationPreferences: "Notifications.seed"
        case .updaterSettings: "Updater.follow"
        case .hibernation: "AppServices.startHibernation"
        case .energySaver: "EnergySaver.follow"
        case .configActions: "ConfigActions.start"
        case .themes: "Themes.start"
        case .bookmarksBar: "Bookmarks.followBar"
        case .daemonPrompts: "DaemonPrompts.start"
        case .localDaemon: "Daemon.start"
        case .featurePolicy: "FeaturePolicyEnforcer.start"
        case .browserProfiles: "BrowserProfiles.load"
        case .homeWorkspace: "Home.startWorkspace"
        case .mouseSideButtons: "MouseSideButtons.start"
        case .keybindingsFile: "KeybindingsFile.start"
        case .bookmarks: "Bookmarks.start"
        case .historyPages: "History.start"
        case .chromiumRuntime: "ChromiumRuntime.start"
        case .cloud: "Cloud.start"
        case .historyRetention: "History.closedRetention"
        case .chromiumLikely: "ChromiumWarmup.followLikely"
        case .bookmarkSync: "Bookmarks.sync"
        }
    }

    /// Runs this start by its class: a first-frame start now (``runNow(on:_:)``); another one posted
    /// (``post(on:_:)``) when `deferring`, else now, where it ran before its class existed.
    ///
    /// - Parameters:
    ///   - startup: The launch's scheduler; nil (an `AppServices` a test builds) runs every start now.
    ///   - deferring: Feature `launchStartDeferral`; false runs every start now.
    ///   - work: The start.
    @MainActor
    public func run(on startup: StartupScheduler?, deferring: Bool, _ work: @escaping @MainActor @Sendable () -> Void) {
        guard startClass == .afterReveal else { return runNow(on: startup) { work() } }
        guard deferring, let startup else { return work() }
        post(on: startup, work)
    }

    /// Posts this start at its class's priority under its name; a first-frame start runs now.
    ///
    /// - Parameters:
    ///   - startup: The launch's scheduler.
    ///   - work: The start.
    @MainActor
    public func post(on startup: StartupScheduler, _ work: @escaping @MainActor @Sendable () -> Void) {
        guard let priority = startClass.priority else { return runNow(on: startup) { work() } }
        startup.post(priority, name, on: .main, work)
    }

    /// Runs a ``LaunchStartClass/firstFrame`` start in the launch turn, inside its `launch.startup_task`
    /// signpost (`priority=launchTurn`) as the watchdog's current task. A start of another class is a
    /// programmer error (a Debug assertion) and still runs.
    ///
    /// - Parameters:
    ///   - startup: The launch's scheduler, whose log signposts the start; nil runs it unsignposted.
    ///   - work: The start.
    /// - Returns: What the start returns.
    @MainActor @discardableResult
    public func runNow<T>(on startup: StartupScheduler?, _ work: () -> T) -> T {
        assert(startClass == .firstFrame, "\(name) is not a first-frame start: run it with run(on:deferring:_:)")
        guard let startup else { return work() }
        return startup.log.runInLaunchTurn(name, work)
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
