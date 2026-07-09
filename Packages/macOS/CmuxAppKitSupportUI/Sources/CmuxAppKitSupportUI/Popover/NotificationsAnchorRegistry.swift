public import AppKit

/// Tracks the live titlebar/sidebar views that may anchor the notifications popover and
/// resolves the one nearest a window point.
///
/// Anchors are held weakly (`NSHashTable.weakObjects`) so deallocated views drop out
/// automatically. `closestAnchor(in:to:)` filters to anchors in the given window that are
/// currently visible popover anchors with a non-empty window-space frame, then returns the
/// one whose frame center is squared-distance closest to the supplied point.
@MainActor
public final class NotificationsAnchorRegistry {
    public static let shared = NotificationsAnchorRegistry()

    private let anchors = NSHashTable<NSView>.weakObjects()

    private init() {}

    public func register(_ view: NSView) {
        guard !anchors.contains(view) else { return }
        anchors.add(view)
    }

    public func closestAnchor(in window: NSWindow, to pointInWindow: NSPoint) -> NSView? {
        anchors.allObjects
            .compactMap { view -> (view: NSView, distance: CGFloat)? in
                guard view.window === window else { return nil }
                guard view.isVisibleAsNotificationsPopoverAnchor else { return nil }
                let frameInWindow = view.convert(view.bounds, to: nil)
                guard !frameInWindow.isEmpty else { return nil }
                let center = NSPoint(x: frameInWindow.midX, y: frameInWindow.midY)
                let dx = center.x - pointInWindow.x
                let dy = center.y - pointInWindow.y
                return (view, (dx * dx) + (dy * dy))
            }
            .min { $0.distance < $1.distance }?
            .view
    }
}
