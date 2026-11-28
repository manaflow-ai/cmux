public import AppKit

extension LayoutRootView {
    /// The pane showing under `point` (this view's coordinates) on the active screen, and the part
    /// of its frame that shows: a docked column's pane over the strip, a strip pane clipped off the
    /// docks and the view's edges. Nil outside the view or between panes (a pane drag, cx-8bv1j).
    public func visiblePane(at point: CGPoint) -> (pane: PaneID, frame: CGRect)? {
        guard bounds.contains(point), let active = model.activeScreenID, let view = screenViews[active], !view.isHidden else { return nil }
        // `convert`, not the frame offset: a canvas screen's bounds are its camera.
        let local = view.convert(point, from: self)
        guard let pane = view.pane(at: local), var frame = view.displayedFrame(of: pane) else { return nil }
        if view.geometry.scrolls(pane: pane) { frame = frame.intersection(view.uncoveredRect) }
        frame = frame.intersection(view.bounds)
        guard !frame.isNull, frame.contains(local) else { return nil }
        return (pane, convert(frame, from: view))
    }

    /// Displayed frame of `pane` in this view's coordinates (active screen only).
    public func frame(of pane: PaneID) -> CGRect? {
        guard let active = model.activeScreenID, let view = screenViews[active], let rect = view.displayedFrame(of: pane) else { return nil }
        return convert(rect, from: view)
    }
    /// Pane bounds after a keyboard split, before the pane exists; nil when the preview cannot predict it.
    public func newSplitPaneSize(splitting pane: PaneID, zone: PaneDropZone) -> CGSize? {
        guard let active = model.activeScreenID, let view = screenViews[active] else { return nil }
        return view.newSplitPaneSize(splitting: pane, zone: zone)
    }

    /// Pane content size after inserting a new pane at an existing divider, before the daemon reply.
    public func newDividerPaneSize(splitting split: SplitID, ratio: Double) -> CGSize? {
        guard let active = model.activeScreenID, let view = screenViews[active] else { return nil }
        return view.newDividerPaneSize(splitting: split, ratio: ratio)
    }

}
