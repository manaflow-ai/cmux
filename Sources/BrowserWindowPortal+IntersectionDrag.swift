import AppKit

/// Two-axis divider intersection drag support for the browser portal host.
///
/// Intersection drags resize two split views at once, which `NSSplitView`
/// cannot do natively, so a host view must claim the mouseDown and drive
/// `PortalDividerIntersectionDragController`. Terminal portals are installed
/// lazily by terminal binding, so a browser-only window would otherwise show
/// the four-way cursor and then hand the click to a native `NSSplitView`
/// that resizes a single axis.
extension WindowBrowserHostView {
    /// Classifies the divider under `windowPoint`: a live nested pair becomes
    /// a `.both` intersection hit; otherwise the topmost region keeps the
    /// legacy single-axis precedence (no orientation preference).
    static func dividerHit(
        at windowPoint: NSPoint,
        in regions: [PortalSplitDividerRegion],
        checkLiveness: Bool = true
    ) -> DividerHit? {
        let hits = PortalSplitDividerRegion.dividerHits(at: windowPoint, in: regions, checkLiveness: checkLiveness)
        if hits.intersection != nil {
            return DividerHit(kind: .both, isInHostedContent: false)
        }
        guard let region = hits.first else { return nil }
        return DividerHit(
            kind: region.isVertical ? .vertical : .horizontal,
            isInHostedContent: region.isInHostedContent
        )
    }

    /// True when a `.both` divider hit at `point` should claim the mouseDown
    /// for a two-axis drag. Gated on the same live-intersection predicate
    /// that `mouseDown` uses to begin the drag (the cursor path skips
    /// liveness); otherwise a non-live pair would swallow the click.
    func claimsIntersectionMouseDown(
        at point: NSPoint,
        eventType: NSEvent.EventType?,
        dividerHitKind: PortalDividerCursorKind?
    ) -> Bool {
        guard dividerHitKind == .both, eventType == .leftMouseDown else { return false }
        return PortalSplitDividerRegion.dividerIntersection(
            at: convert(point, to: nil),
            in: splitDividerRegions()
        ) != nil
    }

    /// Starts a two-axis drag when the mouseDown lands on a live intersection.
    func beginIntersectionDrag(with event: NSEvent) -> Bool {
        intersectionDrag.begin(atWindowPoint: event.locationInWindow, regions: splitDividerRegions())
    }

    /// Forwards a drag sample to the active two-axis drag, if any.
    func updateIntersectionDragIfActive(with event: NSEvent) -> Bool {
        guard intersectionDrag.isActive else { return false }
        intersectionDrag.update(windowPoint: event.locationInWindow)
        return true
    }

    /// Ends the active two-axis drag and re-resolves the cursor from the drop
    /// point so the forced four-way cursor does not stick when the pointer
    /// ends away from any divider.
    func endIntersectionDragIfActive(with event: NSEvent) -> Bool {
        guard intersectionDrag.isActive else { return false }
        intersectionDrag.end()
        updateDividerCursor(at: convert(event.locationInWindow, from: nil))
        return true
    }
}
