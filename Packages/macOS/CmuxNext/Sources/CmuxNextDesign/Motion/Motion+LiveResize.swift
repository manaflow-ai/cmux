public import AppKit

extension Motion {
    /// Whether `window` is in a live resize (the user drags its edge or corner): movement in it
    /// snaps (`MotionPolicy.liveResize`, ``MotionGate/policy(in:)``), so its pane frames, tab
    /// strips and sidebar follow the edge every frame and nothing springs toward a size the next
    /// frame replaces (cx-sqj3h). Starts with the window's `willStartLiveResize` and ends with its
    /// `didEndLiveResize` (or its close). Another window's motion is not held: it animates as usual.
    ///
    /// A full screen enter or exit of `window` counts too (fullscreen-lag; `NSView.inLiveResize`
    /// misses it): AppKit sets the final size at once and animates a snapshot to it, so content
    /// that springs toward a size only shows its in-between frames late.
    ///
    /// A child window is in its parent's resize: AppKit sets `inLiveResize` and posts the
    /// notifications for the dragged window only, and the overlay panel (`WindowOverlayHost`) and
    /// a Chromium page's window are children of it. So the read follows `window.parent`.
    public static func isLiveResizing(_ window: NSWindow?) -> Bool {
        let windows = LiveResizeWindows.shared
        // AppKit windows have a short, finite child-parent chain; the bound is the one of
        // `Motion.canAnimate(in:)`, so a malformed chain cannot make this hot-path read unbounded.
        var current = window
        for _ in 0..<8 {
            guard let window = current else { return false }
            if window.inLiveResize || windows.isResizing(window) || windows.isTransitioning(window) { return true }
            current = window.parent
        }
        return false
    }

    /// A count that goes up each time a live resize or a full screen transition of a window starts or ends (and when
    /// a window closes). An answer that is held for the length of a resize (the divider hover's,
    /// `LayoutViewContext.hoverReaches`) is good only while this count is the one it was taken at: the next resize
    /// or transition has a new count, also when nothing was read between the two.
    public static var liveResizeChanges: Int { LiveResizeWindows.shared.changes }

    /// Starts the app's live-resize tracker: from now on it sees every window's live resize and
    /// full screen transition. The app calls this when it makes a main window, before the window
    /// is ordered in (``MotionGate/windowOpenBehavior(restoring:)``, `WindowManager`), so a
    /// transition that starts before the first per-window motion read is not missed for its
    /// whole length. A second call does nothing.
    public static func startLiveResizeTracking() { _ = LiveResizeWindows.shared }

    /// Some window is between `willEnterFullScreen` and `didEnterFullScreen`
    /// (or the exit pair): terminals hold their grid for the daemon until it
    /// ends (`ResizeCoordinator`), so the PTY reflows once, at the final size.
    public static var isFullScreenTransitioning: Bool { LiveResizeWindows.shared.isFullScreenTransitionActive }

    /// Whether `window` is between `willEnterFullScreen` and `didEnterFullScreen` (or the exit pair):
    /// its terminals hold their grid until it ends (`ResizeCoordinator`); other windows' do not.
    public static func isFullScreenTransitioning(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return LiveResizeWindows.shared.isTransitioning(window)
    }

    /// Ends `window`'s full screen transition that AppKit gave up on: its
    /// delegate's `windowDidFailToEnterFullScreen` or
    /// `windowDidFailToExitFullScreen` (no notification is posted for them).
    public static func fullScreenTransitionFailed(_ window: NSWindow) { LiveResizeWindows.shared.endTransition(of: window) }
}

/// The windows between `willStartLiveResize` and `didEndLiveResize`, and the
/// windows in a full screen transition (`willEnterFullScreen` to
/// `didEnterFullScreen`, and the exit pair; a failed one ends through
/// ``Motion/fullScreenTransitionFailed(_:)``, AppKit posts nothing for it).
/// Observes every window from the creation of the app's first main window
/// (``Motion/startLiveResizeTracking()``), before that window is ordered in.
final class LiveResizeWindows {
    /// The app's tracker. Tests put one on a private center here, instead of posting AppKit's
    /// notifications to the process-wide center (check-test-notification-centers.sh), and put the app's back.
    static var shared = LiveResizeWindows()
    private var resizing: Set<ObjectIdentifier> = []
    private var transitioning: Set<ObjectIdentifier> = []
    /// Goes up with each start and each end that this tracker sees (``Motion/liveResizeChanges``).
    private(set) var changes = 0

    /// `window` is between its `willStartLiveResize` and its `didEndLiveResize` (or its close).
    func isResizing(_ window: NSWindow) -> Bool { resizing.contains(ObjectIdentifier(window)) }
    /// Some window is entering or leaving full screen.
    var isFullScreenTransitionActive: Bool { !transitioning.isEmpty }
    func isTransitioning(_ window: NSWindow) -> Bool { transitioning.contains(ObjectIdentifier(window)) }
    /// A transition AppKit gave up on (`windowDidFailToEnterFullScreen`, `windowDidFailToExitFullScreen`).
    func endTransition(of window: NSWindow) {
        transitioning.remove(ObjectIdentifier(window))
        changes += 1
    }

    init(center: NotificationCenter = .default) {
        let changes: [(Notification.Name, Bool)] = [
            (NSWindow.willStartLiveResizeNotification, true),
            (NSWindow.didEndLiveResizeNotification, false),
            (NSWindow.willCloseNotification, false),
        ]
        for (name, resizing) in changes {
            let closes = name == NSWindow.willCloseNotification
            // The token lives as long as the process: this object never goes away.
            _ = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                let id = ObjectIdentifier(window)
                MainActor.assumeIsolated { // main-proof: AppKit posts window notifications on the main thread
                    if resizing { self?.resizing.insert(id) } else { self?.resizing.remove(id) }
                    if closes { self?.transitioning.remove(id) }
                    self?.changes += 1
                }
            }
        }
        let transitions: [(Notification.Name, Bool)] = [
            (NSWindow.willEnterFullScreenNotification, true), (NSWindow.didEnterFullScreenNotification, false),
            (NSWindow.willExitFullScreenNotification, true), (NSWindow.didExitFullScreenNotification, false),
        ]
        for (name, starts) in transitions {
            // The token lives as long as the process: this object never goes away.
            _ = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                let id = ObjectIdentifier(window)
                MainActor.assumeIsolated { // main-proof: AppKit posts window notifications on the main thread
                    if starts { self?.transitioning.insert(id) } else { self?.transitioning.remove(id) }
                    self?.changes += 1
                }
            }
        }
    }
}
