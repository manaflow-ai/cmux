import AppKit
import CmuxNextDesign

/// FRAME OWNER REFACTOR S3c: a springing close keeps the closed pane's host on the screen, showing only its own ground,
/// on a frame that collapses on its neighbours' spring (``ClosingPanes``), so no frame of the close shows the shell where
/// the pane was (the F2 hole: 710 px in a pane close, 530 px in a column close). On a canvas the host hides in the close's
/// turn, as before S3c.
extension ScreenContentView {
    /// The panes `closing` left the layout in a close that springs (`reconcile`): each host retires, shown with its ground
    /// on what its neighbours and its row column's scroll have not covered yet (hidden on a canvas).
    /// Which ones nothing closes over is known once the change's cameras are set (``settleClosing()``): the panes the strip
    /// carries start moving only then. `frame`: where it showed, before this change carried the strip.
    func retireClosing(_ closing: [(pane: PaneID, frame: AnimatedFrame?)], before: ScreenGeometry, carried: Bool, offset: CGFloat) {
        guard !closing.isEmpty else { return }
        guard !isCanvas else {
            for (pane, _) in closing { context.retire(pane, from: screenID) }
            return
        }
        let style = context.style, viewShift = carried ? baseGeometry.viewShift(offset: offset) : nil
        let kept = ClosingPanes.handles(of: baseGeometry)
        for (pane, frame) in closing {
            guard let frame, context.hosts[pane]?.superview === self else { continue }
            // In the new layout's coordinates, as the live frames this change carried (`reconcile`).
            let drift = carried && before.scrolls(pane: pane) ? before.viewShift(offset: offset) - baseGeometry.viewShift(offset: offset) : 0
            closingPanes.begin(pane, shown: frame.rect.offsetBy(dx: drift, dy: 0), before: before, kept: kept,
                               maxGap: max(style.columnGap, style.dividerHitThickness) + 1, rank: liveRank(of: pane, in: before), viewShift: viewShift,
                               stripShift: before.viewShift(offset: offset))
        }
        for (pane, _) in closing { context.retire(pane, from: screenID, showsGround: closingPanes.entries[pane] != nil) }
    }

    /// The change's cameras are set (`syncScroll`, before the change's first frame: the strip's, with the panes it carried
    /// from where they showed, and the row columns' scrolls): the panes it began closing take their row column's scroll
    /// travel (``ClosingPanes/settle(frames:row:)``), the ones nothing moves over hide now, as before S3c, and with
    /// nothing moving on the screen the hosts its closes retired go now (`reconcile` leaves that to this while closing panes
    /// wait for the cameras).
    ///
    /// The panes that stay are placed here one time, with nothing shown: the rules take each side's start at their first
    /// placement (`ClosingPanesRules.rects`), and it must be the frames the line above just read. A key's turn holds the
    /// presentation for the next frame tick (`LayoutRootView.syncWithModelForNextFrame`), one spring step later: a
    /// neighbour with a little more than half a point to go here has less than that there, so a pane kept for that
    /// neighbour's travel got no travel at its first placement and kept its whole place until the landing took it away.
    func settleClosing() {
        guard closingPanes.hasAwaiting else { return }
        let still = closingPanes.settle(frames: paneFrames, row: rowScrollTravel)
        for pane in still {
            closingPanes.drop(pane)
            context.closingHost(pane, of: screenID)?.isHidden = true
        }
        if !closingPanes.isEmpty {
            let restStrip = geometry.viewShift(offset: isUserScrolling ? scroll.value : scroll.target)
            _ = closingPanes.rects(frames: paneFrames, fixed: geometry.fixedPanes, row: rowScrollTravel, strip: stripShift, restStrip: restStrip)
        }
        if !hasMotion { releaseClosing() }
    }

    /// Whether a landing in this frame would move a side of a closing pane more than `snap` from where this frame's step
    /// put it, taking its ground away at once (``ClosingPanes/landingMovesAClosingPane(frames:fixed:restStrip:snap:)``).
    /// With every live frame on its target (the panes landed; a camera or an alpha still moves) a landing moves nothing.
    func landingMovesAClosingPane(snap: CGFloat) -> Bool { // perf-hot: 4ms motion-frame
        guard !closingPanes.isEmpty, paneFrames.values.contains(where: { $0.rect != $0.targetRect }) else { return false }
        let restStrip = geometry.viewShift(offset: isUserScrolling ? scroll.value : scroll.target)
        return closingPanes.landingMovesAClosingPane(frames: paneFrames, fixed: geometry.fixedPanes, restStrip: restStrip, snap: snap)
    }

    /// Where `column`'s row scroll is and where it rests (nil: its rows do not scroll).
    func rowScrollTravel(_ column: ColumnID) -> ClosingPanes.Travel? {
        rowScrolls[column].map { (now: $0.state.spring.value, target: $0.state.spring.target) }
    }

    /// A close taken back before it landed: the pane's live frame starts where its closing frame shows, with its sides'
    /// velocities.
    func takeBackClosing(_ pane: PaneID) -> AnimatedFrame? {
        closingPanes.remove(pane, frames: paneFrames, fixed: geometry.fixedPanes, strip: stripShift)
    }

    /// The screen's motion landed (or it settles at once, or it goes: `until` nil): the hosts its closes retired are torn
    /// down (`LayoutViewContext.releaseRetired`), and their closing frames with them.
    func releaseClosing(until: LayoutViewContext.Retirement? = .landing) {
        context.releaseRetired(of: screenID, until: until)
        closingPanes = ClosingPanes()
    }

    /// Places each closing host at its frame this frame (the strip's, its row column's and its scroll area's offsets as
    /// a live pane's), on the pixel grid; one whose host went (the motion landed) or came back is dropped. Returns the hosts
    /// placed, to clip as the live ones, and whether a frame changed. `strip`, `restStrip`: the strip's view shift now and
    /// where it rests.
    func presentClosingPanes(strip: CGFloat, restStrip: CGFloat, scale: CGFloat) -> (hosts: [(host: PaneHostView, scrolls: Bool)], changed: Bool) { // perf-hot: 4ms motion-frame
        guard !closingPanes.isEmpty else { return ([], false) }
        var hosts: [(host: PaneHostView, scrolls: Bool)] = [], changed = false
        let rects = closingPanes.rects(frames: paneFrames, fixed: geometry.fixedPanes, row: rowScrollTravel, strip: strip, restStrip: restStrip)
        for (pane, entry) in closingPanes.entries {
            guard let host = context.closingHost(pane, of: screenID), host.superview === self, let rect = rects[pane] else {
                closingPanes.drop(pane)
                continue
            }
            let row = entry.rowColumn.flatMap { rowScrolls[$0]?.state.spring.value } ?? 0
            let area = entry.area.flatMap { areaScrolls[$0]?.state.spring.value } ?? 0
            let placed = rect.offsetBy(dx: (entry.scrolls ? strip : 0) - area, dy: -row).pixelEdges(scale)
            if host.frame != placed {
                host.frame = placed
                changed = true
            }
            hosts.append((host, entry.scrolls))
        }
        return (hosts, changed)
    }
}
