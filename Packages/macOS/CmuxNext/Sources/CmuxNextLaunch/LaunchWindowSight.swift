public import AppKit
import CmuxNextDesign
public import CmuxNextWakeups

/// Whether the person sees a window of the launch (p08-startup-095). A launch that shows none (launched hidden,
/// every window closed or minimized, or ordered behind other apps' windows that cover it with
/// `CMUX_NEXT_NO_ACTIVATE=1`) has no first frame and no visible pane to wait for: startup completes with
/// `noWindow` (``VisiblePaneRefs/launchShowedNoWindow(startup:images:)``). Chrome's `StartupObserver::Start`
/// (chrome/browser/after_startup_task_utils.cc) waits for a page load only when a visible WebContents exists.
///
/// The restore decides at once only from facts already current (``Verdict/noWindow``). Occlusion is not one in
/// the turn the windows were ordered in: the system reports it later, so a launch ordered behind other apps'
/// windows keeps its pane refs and ``LaunchCoverWatch`` decides from the system's notices.
///
/// ```swift
/// let sight = LaunchWindowSight(appHidden: NSApp.isHidden, orderedBehind: behind, coming: waiting, windows: windows)
/// if sight.verdict == .noWindow { return paneRefs.launchShowedNoWindow(startup: startup, images: images) }
/// paneRefs.restoreFinished { launchWindows() }
/// if behind { paneRefs.watchCover(of: windows, sight: { readSight() }, startup: startup, images: images) }
/// ```
public struct LaunchWindowSight: Sendable {
    /// One launch window ordered in.
    public struct Shown: Sendable {
        /// Ordered in and not minimized.
        public var onScreen: Bool
        /// The system reports part of it visible (`NSWindow.occlusionState`).
        public var unoccluded: Bool

        public init(onScreen: Bool, unoccluded: Bool) {
            self.onScreen = onScreen
            self.unoccluded = unoccluded
        }
    }

    /// What the person sees of the launch.
    public enum Verdict: Sendable, Equatable {
        /// No window, by facts that are current when read: the app is hidden, or no window is coming and each one
        /// is closed or minimized.
        case noWindow
        /// A window shows: ordered in front, coming in front, or reported unoccluded.
        case shows
        /// Ordered behind every other app's windows and none reported unoccluded: only the system's occlusion
        /// tells whether one shows (``LaunchCoverWatch``).
        case mayBeCovered
    }

    /// The app is hidden (launched hidden, or Cmd-H since): no window shows.
    public var appHidden: Bool
    /// The launch orders its windows behind every other app's (``ordersBehind(noActivate:testScreen:)``): only the
    /// system's occlusion says whether one shows. A window ordered in front shows.
    public var orderedBehind: Bool
    /// Windows that order in once their content or their launch build comes.
    public var coming: Int
    /// The launch windows ordered in.
    public var shown: [Shown]

    public init(appHidden: Bool, orderedBehind: Bool, coming: Int, shown: [Shown]) {
        self.appHidden = appHidden
        self.orderedBehind = orderedBehind
        self.coming = coming
        self.shown = shown
    }

    /// The sight of `windows` (the launch's, ordered in or not) now.
    @MainActor
    public init(appHidden: Bool, orderedBehind: Bool, coming: Int, windows: [NSWindow]) {
        let shown = windows.filter(\.isVisible).map {
            Shown(onScreen: VisiblePaneRefs.Window.isOnScreen($0), unoccluded: $0.occlusionState.contains(.visible))
        }
        self.init(appHidden: appHidden, orderedBehind: orderedBehind, coming: coming, shown: shown)
    }

    /// What the person sees now.
    public var verdict: Verdict {
        let onScreen = shown.filter(\.onScreen)
        if appHidden || (coming == 0 && onScreen.isEmpty) { return .noWindow }
        if !orderedBehind || onScreen.contains(where: \.unoccluded) { return .shows }
        return .mayBeCovered
    }

    /// A presented window goes behind every other app's: `CMUX_NEXT_NO_ACTIVATE=1` without a test screen
    /// (`WindowActivation.plan`).
    public static func ordersBehind(noActivate: Bool, testScreen: Bool) -> Bool {
        WindowActivation.plan(.present, noActivate: noActivate, testScreen: testScreen).order == .orderBack
    }
}

extension VisiblePaneRefs {
    /// The launch shows no window: the first-frame ref, the launch images' ref, then every ref still held here (the
    /// restore's when the restore just ended, else the visible panes') end with `noWindow`, the last of them here, so
    /// `noWindow` is the completion reason. No pane takes a ref after.
    public func launchShowedNoWindow(startup: StartupScheduler?, images: LaunchImageHold) {
        startup?.launchShowedNoWindow()
        images.launchShowedNoWindow()
        releaseAll(.noWindow)
    }

    /// The restore ended with `windows` ordered behind other apps' windows: the system's occlusion decides whether one
    /// shows (``LaunchCoverWatch``). When none does, ``launchShowedNoWindow(startup:images:)`` ends the refs still held.
    ///
    /// - Parameters:
    ///   - windows: The launch's windows ordered in.
    ///   - center: Where the windows post (tests pass their own).
    ///   - timer: The watch's bound; tests inject a manual clock.
    ///   - sight: The launch's sight now; nil ends the watch.
    ///   - startup: The scheduler whose first-frame ref a covered launch ends.
    ///   - images: The launch images' hold, which a covered launch ends.
    public func watchCover(of windows: [NSWindow], center: NotificationCenter = .default,
                           timer: DemandTimer = DemandTimer(owner: "LaunchCoverWatch.bound"),
                           sight: @escaping @MainActor () -> LaunchWindowSight?, startup: StartupScheduler?, images: LaunchImageHold) {
        // The watch holds this object until it decides (within its bound): a covered launch ends these refs.
        let watch = LaunchCoverWatch(timer: timer, sight: sight) { [self] in launchShowedNoWindow(startup: startup, images: images) }
        cover = watch
        watch.follow(windows, center: center)
    }
}
