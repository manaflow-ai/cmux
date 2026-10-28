import AppKit
import QuartzCore

/// Where a press lands in a screen: at rest on the views' frames, mid render-server spring where the views
/// are drawn.
extension ScreenContentView {
    /// Clicks inside what a docked column covers go to the docked column
    /// (its panes, dividers, handle) or to this view, never to a strip pane
    /// under it (an overlay column's glass shows the strip under it).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // Render-server springs draw panes and dividers away from their rest frames.
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
    /// inside the range it shows; a divider on a spring takes none until it lands, a resting one takes its
    /// press as at rest. As at rest, a press inside a docked column's cover never reaches the strip, unless
    /// the strip still shows there while the column grows in or a zoom lifts it above the docks, and a zoom's
    /// covered panes take none.
    private func drawnHit(at local: CGPoint) -> NSView? {
        guard bounds.contains(local) else { return nil }
        let docked = geometry.dock.contains { $0.cover.contains(local) }
        for view in subviews.reversed() where !view.isHidden {
            if view === stripContainer {
                if let hit = stripHit(local, docked: docked) { return hit }
            } else if let host = view as? PaneHostView {
                if covered.contains(host.pane) || (docked && geometry.scrolls(pane: host.pane)) { continue }
                if let hit = host.hitTest(local) { return hit }
            } else if let divider = view as? DividerHandleView {
                if isSpringing(divider) || (docked && scrolls(divider.kind)) { continue }
                if let hit = divider.hitTest(local) { return hit }
            } else if let hit = view.hitTest(local) {
                return hit
            }
        }
        return self
    }

    /// What the strip container takes of a press at `local` (this view's coordinates) mid render-server spring.
    /// Lifted for a zoom (``liftsStripContainer``), it is in front of the docks: the zooming host takes the
    /// press wherever it is drawn, and the other strip hosts only inside the strip's range outside the docks'
    /// covers, because the masks that clip them there (``heldStripClip(of:fronts:)``) do not stop a hit test.
    private func stripHit(_ local: CGPoint, docked: Bool) -> NSView? {
        guard stripContainer.isLifted else {
            return stripPoint(local, docked: docked).flatMap { stripChildHit($0, besides: nil) }
        }
        let inner = stripContainer.convert(local, from: self)
        let zooming = zoomMotion.pane.flatMap { context.hosts[$0] }.flatMap { $0.isDescendant(of: stripContainer) ? $0 : nil }
        if let zooming, let hit = zooming.hitTest(inner) { return hit }
        guard !docked, stripContainer.range.contains(local) else { return nil }
        return stripChildHit(inner, besides: zooming)
    }

    /// The front-most of the strip container's views drawn at `inner` (its coordinates), leaving out `skipped`,
    /// a zoom's covered hosts and the dividers on a spring. A row's or scroll area's container is walked the
    /// same way (its coordinates are the strip container's), inside its clip.
    private func stripChildHit(_ inner: CGPoint, besides skipped: PaneHostView?, in container: NSView? = nil) -> NSView? {
        for child in (container ?? stripContainer).subviews.reversed() where !child.isHidden && child !== skipped {
            if let nested = child as? ScrollerPanContainerView {
                guard !nested.clipsSubviews || nested.frame.contains(inner) else { continue }
                if let hit = stripChildHit(inner, besides: skipped, in: nested) { return hit }
                continue
            }
            if let host = child as? PaneHostView, covered.contains(host.pane) { continue }
            if let divider = child as? DividerHandleView, isSpringing(divider) { continue }
            if let hit = child.hitTest(inner) { return hit }
        }
        return nil
    }

    /// `divider` is drawn away from its rest frame on a render-server spring (``renderTracks``).
    private func isSpringing(_ divider: DividerHandleView) -> Bool { renderTracks.dividers[divider.kind] != nil }

    /// `local` (this view's coordinates) in the strip container's, where the strip shows there; nil where it
    /// does not. While the container's range springs with a docked column growing in, its drawn frame and
    /// bounds take the press (`springStripContainer`), never inside an overlay column's cover (its glass shows
    /// the strip under it and takes the press); else its frame outside every docked column's cover.
    private func stripPoint(_ local: CGPoint, docked: Bool) -> CGPoint? {
        guard renderTracks.strip, let drawn = stripContainer.layer?.presentation() else {
            return !docked && stripContainer.frame.contains(local) ? stripContainer.convert(local, from: self) : nil
        }
        guard !geometry.dock.contains(where: { $0.dock.mode == .overlay && $0.cover.contains(local) }) else { return nil }
        let point = convertToLayer(local)
        guard drawn.frame.contains(point) else { return nil }
        return stripContainer.convertFromLayer(CGPoint(x: point.x - drawn.frame.minX + drawn.bounds.minX,
                                                       y: point.y - drawn.frame.minY + drawn.bounds.minY))
    }

    /// The pane a press at `local` (this view's coordinates) focuses: the one drawn there while render-server
    /// springs run (``drawnHit(at:)``, counted in ``LayoutRootView/pressesMidRenderSpring``), else the model's
    /// (``pane(at:)``), which reads no layer. The root's press intercept asks it once per press.
    func pressedPane(at local: CGPoint) -> PaneID? {
        guard !isHidden, !renderTracks.isEmpty else { return pane(at: local) }
        context.pressesMidRenderSpring += 1
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
