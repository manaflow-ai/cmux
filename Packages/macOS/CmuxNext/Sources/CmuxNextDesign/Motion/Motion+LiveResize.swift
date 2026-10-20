public import AppKit

extension Motion {
    /// Some window is in a live resize (the user drags its edge or corner):
    /// movement snaps (`MotionPolicy.liveResize`), so pane frames, tab strips
    /// and the sidebar follow the edge every frame and nothing springs toward
    /// a size the next frame replaces (cx-sqj3h). Starts with the window's
    /// `willStartLiveResize` and ends with its `didEndLiveResize` (or its close).
    public static var isLiveResizing: Bool { liveResizeOverride ?? LiveResizeWindows.shared.isActive }

    /// Tests set a live resize here instead of posting AppKit's notifications
    /// to the process-wide center (check-test-notification-centers.sh).
    static var liveResizeOverride: Bool?
}

/// The windows between `willStartLiveResize` and `didEndLiveResize`. Observes
/// every window from the first read of `Motion.policy`, long before a person
/// can drag an edge.
final class LiveResizeWindows {
    static let shared = LiveResizeWindows()
    private var resizing: Set<ObjectIdentifier> = []

    var isActive: Bool { !resizing.isEmpty }

    init(center: NotificationCenter = .default) {
        let changes: [(Notification.Name, Bool)] = [
            (NSWindow.willStartLiveResizeNotification, true),
            (NSWindow.didEndLiveResizeNotification, false),
            (NSWindow.willCloseNotification, false),
        ]
        for (name, resizing) in changes {
            // The token lives as long as the process: this object never goes away.
            _ = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                let id = ObjectIdentifier(window)
                MainActor.assumeIsolated { // main-proof: AppKit posts window notifications on the main thread
                    if resizing { self?.resizing.insert(id) } else { self?.resizing.remove(id) }
                }
            }
        }
    }
}
