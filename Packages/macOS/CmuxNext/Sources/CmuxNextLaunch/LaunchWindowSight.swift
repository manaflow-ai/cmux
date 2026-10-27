public import AppKit
import CmuxNextDesign
public import CmuxNextWakeups

/// Whether the person sees a window of the launch (p08-startup-095). A launch that shows none (launched hidden,
/// every window closed or minimized, or ordered behind other apps' windows that cover it with
/// `CMUX_NEXT_NO_ACTIVATE=1`) has no first frame and no visible pane to wait for: startup completes with
/// `noWindow` (``VisiblePaneRefs/restoreShowedNoWindow(startup:images:)``). Chrome's `StartupObserver::Start`
/// (chrome/browser/after_startup_task_utils.cc) waits for a page load only when a visible WebContents exists.
///
/// ```swift
/// let sight = LaunchWindowSight(appHidden: NSApp.isHidden, orderedBehind: behind, coming: waiting, windows: windows)
/// if sight.showsWindow { paneRefs.finishRestore(of: manager) } else { paneRefs.restoreShowedNoWindow(startup: startup, images: images) }
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

    /// True when a window shows, or one is coming.
    public var showsWindow: Bool {
        !appHidden && (coming > 0 || shown.contains { $0.onScreen && ($0.unoccluded || !orderedBehind) })
    }

    /// Whether the launch window may show its saved picture as its first frame: never in a hidden launch, whose
    /// first frame nobody sees (the read's pixels are dropped instead, ``WindowPictureStore/dropFront()``).
    public static func showsPicture(appHidden: Bool) -> Bool { !appHidden }

    /// A presented window goes behind every other app's: `CMUX_NEXT_NO_ACTIVATE=1` without a test screen
    /// (`WindowActivation.plan`).
    public static func ordersBehind(noActivate: Bool, testScreen: Bool) -> Bool {
        WindowActivation.plan(.present, noActivate: noActivate, testScreen: testScreen).order == .orderBack
    }
}

extension VisiblePaneRefs {
    /// The restore ended and the launch shows no window: the first-frame ref, the launch images' ref and the restore
    /// ref end with `noWindow`, the restore's last, so `noWindow` is the completion reason. No pane takes a ref.
    public func restoreShowedNoWindow(startup: StartupScheduler?, images: LaunchImageHold) {
        startup?.launchShowedNoWindow()
        images.launchShowedNoWindow()
        restoreFinished { () -> [Window] in [] }
    }
}
