public import AppKit

/// The views floating over a page's content column right under its header (Home's import
/// cards). The column's own centered content (Home's first-run panel) starts below them instead
/// of drawing under them. An overlay registers once and calls ``changed()`` when it shows, hides
/// or changes height; columns lay out again on `cmuxColumnTopOverlayDidChange`.
@MainActor
public final class ColumnTopOverlays {
    public static let shared = ColumnTopOverlays()

    private let live = NSHashTable<NSView>.weakObjects()

    /// Makes `overlay` count until it is deallocated.
    public func register(_ overlay: NSView) { live.add(overlay) }

    /// Tells the columns an overlay moved, showed or hid.
    public func changed() {
        NotificationCenter.default.post(name: .cmuxColumnTopOverlayDidChange, object: nil)
    }

    /// How far from `view`'s top the shown overlays over it in its window reach; nil when none does.
    public func reach(over view: NSView) -> CGFloat? {
        guard let window = view.window else { return nil }
        var reach: CGFloat?
        for overlay in live.allObjects where overlay.window === window && !overlay.isHiddenOrHasHiddenAncestor {
            let rect = view.convert(overlay.bounds, from: overlay)
            guard rect.intersects(view.bounds) else { continue }
            reach = max(reach ?? 0, view.isFlipped ? rect.maxY : view.bounds.height - rect.minY)
        }
        return reach
    }
}

extension Notification.Name {
    /// Posted when a ``ColumnTopOverlays`` view shows, hides or changes height.
    public static let cmuxColumnTopOverlayDidChange = Notification.Name("CmuxNextDesign.columnTopOverlayDidChange")
}
