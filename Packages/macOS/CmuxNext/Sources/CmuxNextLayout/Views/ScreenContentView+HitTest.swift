import AppKit
import QuartzCore

/// Where a press lands in a screen: at rest on the views' frames, mid render-server spring where the views
/// are drawn (chrome-parity p03-rendering-098).
extension ScreenContentView {
    /// Clicks inside what a docked column covers go to the docked column
    /// (its panes, dividers, handle) or to this view, never to a strip pane
    /// under it (an overlay column's glass shows the strip under it).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // Render-server springs draw panes and dividers away from their rest frames (p03-rendering-098).
        if !isHidden, !renderTracks.isEmpty { return drawnHit(at: local) }
        guard !isHidden, geometry.dock.contains(where: { $0.cover.contains(local) }) else {
            // A zoom's covered panes have left the layout: a click there goes to this view.
            let hit = super.hitTest(point)
            guard !covered.isEmpty, let hit, coveredHost(containing: hit) != nil else { return hit }
            return self
        }
        for view in subviews.reversed() where !view.isHidden && view !== stripContainer {
            if let host = view as? PaneHostView, geometry.scrolls(pane: host.pane) || covered.contains(host.pane) { continue }
            if let divider = view as? DividerHandleView, scrolls(divider.kind) { continue }
            if let hit = view.hitTest(local) { return hit }
        }
        return self
    }

    /// What a press at `local` (this view's coordinates) reaches while render-server springs run
    /// (``renderTracks``): the front-most view drawn there. Each moving host maps the press through its
    /// presentation layer (``PaneHostView/hitTest(_:)``), so only moving hosts read one; the strip takes it
    /// inside the range it shows; divider handles take none until they land, so a divider grab waits for
    /// the landing. As at rest, a press inside a docked column's cover never reaches the strip, unless the
    /// strip still shows there while the column grows in, and a zoom's covered panes take none.
    private func drawnHit(at local: CGPoint) -> NSView? {
        guard bounds.contains(local) else { return nil }
        let docked = geometry.dock.contains { $0.cover.contains(local) }
        for view in subviews.reversed() where !view.isHidden && !(view is DividerHandleView) {
            if view === stripContainer {
                guard let inner = stripPoint(local, docked: docked) else { continue }
                for child in stripContainer.subviews.reversed() where !child.isHidden && !(child is DividerHandleView) {
                    if let host = child as? PaneHostView, covered.contains(host.pane) { continue }
                    if let hit = child.hitTest(inner) { return hit }
                }
            } else if let host = view as? PaneHostView {
                if covered.contains(host.pane) || (docked && geometry.scrolls(pane: host.pane)) { continue }
                if let hit = host.hitTest(local) { return hit }
            } else if let hit = view.hitTest(local) {
                return hit
            }
        }
        return self
    }

    /// `local` (this view's coordinates) in the strip container's, where the strip shows there; nil where it
    /// does not. While the container's range springs with a docked column growing in, its drawn frame and
    /// bounds take the press (`springStripContainer`); else its frame outside every docked column's cover.
    private func stripPoint(_ local: CGPoint, docked: Bool) -> CGPoint? {
        guard renderTracks.strip, let drawn = stripContainer.layer?.presentation() else {
            return !docked && stripContainer.frame.contains(local) ? stripContainer.convert(local, from: self) : nil
        }
        let point = convertToLayer(local)
        guard drawn.frame.contains(point) else { return nil }
        return stripContainer.convertFromLayer(CGPoint(x: point.x - drawn.frame.minX + drawn.bounds.minX,
                                                       y: point.y - drawn.frame.minY + drawn.bounds.minY))
    }

    /// The pane a press at `local` (this view's coordinates) focuses: the one drawn there while render-server
    /// springs run (``drawnHit(at:)``), else the model's (``pane(at:)``), which reads no layer.
    func pressedPane(at local: CGPoint) -> PaneID? {
        guard !isHidden, !renderTracks.isEmpty else { return pane(at: local) }
        var view = drawnHit(at: local)
        while let current = view, current !== self {
            if let host = current as? PaneHostView { return host.pane }
            view = current.superview
        }
        return nil
    }

    private func coveredHost(containing view: NSView) -> PaneHostView? {
        var current: NSView? = view
        while let candidate = current, candidate !== self {
            if let host = candidate as? PaneHostView, covered.contains(host.pane) { return host }
            current = candidate.superview
        }
        return nil
    }
}
