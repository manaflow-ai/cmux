public import AppKit

extension Motion {
    /// Some window is in a live resize (the user drags its edge or corner):
    /// movement snaps (`MotionPolicy.liveResize`), so pane frames, tab strips
    /// and the sidebar follow the edge every frame and nothing springs toward
    /// a size the next frame replaces (cx-sqj3h). Starts with the window's
    /// `willStartLiveResize` and ends with its `didEndLiveResize` (or its close).
    ///
    /// A full screen enter or exit counts too (fullscreen-lag): AppKit sets
    /// the final size at once and animates a snapshot to it, so content that
    /// springs toward a size only shows its in-between frames late.
    public static var isLiveResizing: Bool { liveResizeOverride ?? LiveResizeWindows.shared.isActive }

    /// Whether `window` is in a live resize or a full screen transition: the
    /// per-window form of ``isLiveResizing`` for views that ask about their
    /// own window (`NSView.inLiveResize` misses full screen transitions).
    public static func isLiveResizing(_ window: NSWindow?) -> Bool {
        if let liveResizeOverride { return liveResizeOverride }
        guard let window else { return false }
        return window.inLiveResize || LiveResizeWindows.shared.isTransitioning(window)
    }

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

    /// Tests set a live resize here instead of posting AppKit's notifications
    /// to the process-wide center (check-test-notification-centers.sh).
    static var liveResizeOverride: Bool?
}

/// The windows between `willStartLiveResize` and `didEndLiveResize`, and the
/// windows in a full screen transition (`willEnterFullScreen` to
/// `didEnterFullScreen`, and the exit pair; a failed one ends through
/// ``Motion/fullScreenTransitionFailed(_:)``, AppKit posts nothing for it).
/// Observes every window from the first read of `Motion.basePolicy`, long before
/// a person can drag an edge.
final class LiveResizeWindows {
    static let shared = LiveResizeWindows()
    private var resizing: Set<ObjectIdentifier> = []
    private var transitioning: Set<ObjectIdentifier> = []

    var isActive: Bool { !resizing.isEmpty || !transitioning.isEmpty }
    /// Some window is entering or leaving full screen.
    var isFullScreenTransitionActive: Bool { !transitioning.isEmpty }
    func isTransitioning(_ window: NSWindow) -> Bool { transitioning.contains(ObjectIdentifier(window)) }
    /// A transition AppKit gave up on (`windowDidFailToEnterFullScreen`, `windowDidFailToExitFullScreen`).
    func endTransition(of window: NSWindow) { transitioning.remove(ObjectIdentifier(window)) }

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
                }
            }
        }
    }
}
