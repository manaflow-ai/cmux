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

    /// Presentation-layer reads of this root's pane hit tests (`PaneHostView.presentedHitReads`; `debug.layout_counters`
    /// `presented_hit_reads`, read as a delta): a press mid render-server spring reads one per moving host, at rest none.
    public var presentedHitReads: Int { context.hosts.values.reduce(0) { $0 + $1.presentedHitReads } }

    /// Presses this root's intercept handled while render-server springs ran on its active screen
    /// (`ScreenContentView.pressedPane(at:)`; `debug.layout_counters` `presses_mid_spring`, read as a delta): when a
    /// press came, whatever its hit test read.
    public var pressesMidRenderSpring: Int { context.pressesMidRenderSpring }
}
