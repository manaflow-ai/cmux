import AppKit
import CmuxNextDesign

/// FRAME OWNER REFACTOR S3c: a springing close keeps the closed pane's host on the screen, showing only its own ground,
/// on a frame that collapses on its neighbours' spring (``ClosingPanes``), so no frame of the close shows the shell where
/// the pane was (the F2 hole: 710 px in a pane close, 530 px in a column close). `motion.frameOwner.contentPolicy` off
/// (read at the close): the host hides in the close's turn, as before.
extension ScreenContentView {
    /// `pane` left the layout in a close that springs (`reconcile`): its host retires, shown on its collapsing frame with
    /// the policy on (read now), else hidden. `frame`: where it showed, before this change carried the strip.
    func retireClosing(_ pane: PaneID, frame: AnimatedFrame?, before: ScreenGeometry, carried: Bool, offset: CGFloat) {
        guard context.followsContentPolicy, !isCanvas, let frame, context.hosts[pane]?.superview === self else {
            context.retire(pane, from: screenID)
            return
        }
        // In the new layout's coordinates, as the live frames this change carried (`reconcile`).
        let scrolls = before.scrolls(pane: pane)
        let drift = carried && scrolls ? before.viewShift(offset: offset) - baseGeometry.viewShift(offset: offset) : 0
        let style = context.style
        closingPanes.begin(pane, shown: frame.rect.offsetBy(dx: drift, dy: 0), before: before,
                           maxGap: max(style.columnGap, style.dividerHitThickness) + 1, rank: liveRank(of: pane, in: before),
                           viewShift: carried ? baseGeometry.viewShift(offset: offset) : nil)
        context.retire(pane, from: screenID, showsGround: true)
    }

    /// A close taken back before it landed: the pane's live frame starts where its closing frame shows, with its sides'
    /// velocities.
    func takeBackClosing(_ pane: PaneID) -> AnimatedFrame? { closingPanes.remove(pane, frames: paneFrames) }

    /// The screen's motion landed (or it settles at once, or it goes: `until` nil): the hosts its closes retired are torn
    /// down (`LayoutViewContext.releaseRetired`), and their closing frames with them.
    func releaseClosing(until: LayoutViewContext.Retirement? = .landing) {
        context.releaseRetired(of: screenID, until: until)
        closingPanes = ClosingPanes()
    }

    /// Places each closing host at its frame this frame (the strip's, its row column's and its scroll area's offsets as
    /// a live pane's), on the pixel grid; one whose host went (the motion landed) or came back is dropped. Returns the hosts
    /// placed, to clip as the live ones, and whether a frame changed.
    func presentClosingPanes(strip: CGFloat, scale: CGFloat) -> (hosts: [(host: PaneHostView, scrolls: Bool)], changed: Bool) { // perf-hot: 4ms motion-frame
        guard !closingPanes.isEmpty else { return ([], false) }
        var hosts: [(host: PaneHostView, scrolls: Bool)] = [], changed = false
        let rects = closingPanes.rects(frames: paneFrames)
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
