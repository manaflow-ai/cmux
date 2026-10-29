public import AppKit

/// A view inside a ``RestingPlacement`` whose content shows in another window placed from the view's frame (a
/// Chromium page window): it hears when Core Animation starts and stops showing the placement away from that
/// frame (``RestingPlacement/showsRenderMove``), so that window can hide meanwhile. Told at a render spring's
/// start, at its landing and when the main thread takes it back, never per frame, and only by a placement
/// with ``RestingPlacement/pageResizing``.
@MainActor
public protocol PaneRenderMoveObserving: NSView {
    func paneRenderMoveDidChange(_ showsRenderMove: Bool)
}

public extension NSView {
    /// Tells every ``PaneRenderMoveObserving`` view in this subtree (this view included) whether its placement
    /// shows a render-server move now.
    func notifyPaneRenderMoveChanged(_ showsRenderMove: Bool) {
        if let observing = self as? PaneRenderMoveObserving { observing.paneRenderMoveDidChange(showsRenderMove) }
        for subview in subviews { subview.notifyPaneRenderMoveChanged(showsRenderMove) }
    }
}
