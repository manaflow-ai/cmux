import CoreGraphics
import CmuxNextDesign

/// FRAME OWNER REFACTOR S3c (`motion.frameOwner.contentPolicy`, read at the close): the panes a springing close took out
/// of one screen, each still shown with only its own ground (`PaneHostView.showClosingGround`) on the space its
/// neighbours have not covered yet.
///
/// A closing pane has no motion of its own: in each frame its rect is a function of its neighbours' frames, so the one
/// owner of the motion is the neighbours' springs. Each side a neighbour closes over sits on the slowest neighbour's
/// facing edge on that side (the leading edge on the smallest trailing edge beside it, the trailing edge on the largest
/// leading edge): nothing between the closing pane and any of its neighbours shows the shell, and where a faster
/// neighbour has passed over it, that live pane draws above it (closing hosts stack under every live host,
/// `ScreenContentView.ensureStacking`). With neighbours on both sides of an axis, the leading side keeps the gap it had to
/// them (the divider that stays), so the pane rests at zero width where they meet. A side whose neighbour closed too
/// rides that closing pane's facing edge; a side with no neighbour (the screen's edge, a docked column's side) stays
/// where it showed. Chrome's tab close does the same: the closing tab shrinks to zero width on the strip's own animation.
/// The host goes when the motion lands (`ScreenContentView.releaseClosing`); a close taken back starts the pane's live
/// frame from where it shows, with its neighbours' velocities.
struct ClosingPanes {
    /// One side of a closing pane: the panes across it in the layout it left, the gap it keeps to them, and where it
    /// stands when none of them is on the screen (its fixed place, or where they last were).
    struct Side {
        let neighbours: [PaneID]
        let gap: CGFloat
        var fixed: CGFloat
    }

    struct Entry {
        var minX: Side, maxX: Side, minY: Side, maxY: Side
        /// It scrolls with the strip (not a docked pane), and the row column and scroll area it showed in.
        let scrolls: Bool
        let rowColumn: ColumnID?
        let area: SplitID?
        /// Its stacking rank when it closed (`ScreenContentView.rank`): it stays under the live hosts of that rank.
        let rank: Int
        /// Where its fixed x sides showed (view x) before the change's camera moved (`settleCarried`); nil once placed.
        var carriedShown: (minX: CGFloat, maxX: CGFloat)?
    }

    private(set) var entries: [PaneID: Entry] = [:]
    /// The order the panes closed in, the order they are placed in each frame: a side on a pane that closed earlier reads
    /// where it shows in this frame; one on a pane that closed later keeps where it last was (that pane's side there stays
    /// put, since the earlier one is not live for it).
    private var order: [PaneID] = []

    var isEmpty: Bool { entries.isEmpty }

    /// Starts `pane` closing. `shown`: where it shows, in the new layout's coordinates; `before`: the layout it left (its
    /// neighbours and the gaps beside them); `maxGap`: the widest gap between two neighbours (a column gap); `rank`: its
    /// stacking rank at the close; `viewShift`: the strip's view shift in the new layout before the camera moves (what
    /// ``settleCarried(stripShift:)`` measures from), nil when nothing was carried.
    mutating func begin(_ pane: PaneID, shown: CGRect, before: ScreenGeometry, maxGap: CGFloat, rank: Int, viewShift: CGFloat?) {
        guard let rest = before.panes[pane] else { return }
        var lead: [(PaneID, CGFloat)] = [], trail: [(PaneID, CGFloat)] = [], top: [(PaneID, CGFloat)] = [], bottom: [(PaneID, CGFloat)] = []
        let scrolls = before.scrolls(pane: pane), area = before.scrollAreaOfPane[pane], rowColumn = before.rowColumnOfPane[pane]
        // Only a neighbour shown in the same space: the strip or a dock, the same scroll area (its x) and row column (its y).
        for (other, was) in before.panes where other != pane && before.scrolls(pane: other) == scrolls {
            if min(was.maxY, rest.maxY) - max(was.minY, rest.minY) > 1, before.scrollAreaOfPane[other] == area {
                let gapBefore = rest.minX - was.maxX, gapAfter = was.minX - rest.maxX
                if gapBefore >= -0.5, gapBefore <= maxGap { lead.append((other, max(0, gapBefore))) }
                if gapAfter >= -0.5, gapAfter <= maxGap { trail.append((other, max(0, gapAfter))) }
            }
            if min(was.maxX, rest.maxX) - max(was.minX, rest.minX) > 1, before.rowColumnOfPane[other] == rowColumn {
                let gapAbove = rest.minY - was.maxY, gapBelow = was.minY - rest.maxY
                if gapAbove >= -0.5, gapAbove <= maxGap { top.append((other, max(0, gapAbove))) }
                if gapBelow >= -0.5, gapBelow <= maxGap { bottom.append((other, max(0, gapBelow))) }
            }
        }
        /// The leading side keeps its gap only when the trailing side has neighbours too (they meet where it rests).
        func side(_ found: [(PaneID, CGFloat)], keepsGap: Bool, at value: CGFloat) -> Side {
            Side(neighbours: found.map(\.0).sorted { $0.rawValue < $1.rawValue }, gap: keepsGap ? found.map(\.1).min() ?? 0 : 0, fixed: value)
        }
        entries[pane] = Entry(minX: side(lead, keepsGap: !trail.isEmpty, at: shown.minX), maxX: side(trail, keepsGap: false, at: shown.maxX),
                              minY: side(top, keepsGap: !bottom.isEmpty, at: shown.minY), maxY: side(bottom, keepsGap: false, at: shown.maxY),
                              scrolls: scrolls, rowColumn: rowColumn, area: area, rank: rank,
                              carriedShown: viewShift.map { scrolls ? (shown.minX + $0, shown.maxX + $0) : (shown.minX, shown.maxX) })
        order.removeAll { $0 == pane }
        order.append(pane)
    }

    /// Where every closing pane shows this frame, from the live panes' presented frames (`frames`, the screen's springs).
    /// A side whose neighbours are all gone (closed and landed, or taken out) keeps where they last were.
    mutating func rects(frames: [PaneID: AnimatedFrame]) -> [PaneID: CGRect] { // perf-hot: 4ms motion-frame
        var shown: [PaneID: CGRect] = [:]
        for pane in order {
            guard var entry = entries[pane] else { continue }
            /// The facing edge of `neighbour`: a live pane's frame, else a closing pane placed earlier in this pass.
            func facing(_ neighbour: PaneID, _ edge: (CGRect) -> CGFloat) -> CGFloat? {
                frames[neighbour].map { edge($0.rect) } ?? shown[neighbour].map(edge)
            }
            func place(_ side: inout Side, slowest: ([CGFloat]) -> CGFloat?, edge: (CGRect) -> CGFloat, sign: CGFloat) {
                guard let value = slowest(side.neighbours.compactMap { facing($0, edge) }) else { return }
                side.fixed = value + sign * side.gap
            }
            place(&entry.minX, slowest: { $0.min() }, edge: \.maxX, sign: 1)
            place(&entry.maxX, slowest: { $0.max() }, edge: \.minX, sign: -1)
            place(&entry.minY, slowest: { $0.min() }, edge: \.maxY, sign: 1)
            place(&entry.maxY, slowest: { $0.max() }, edge: \.minY, sign: -1)
            entries[pane] = entry
            shown[pane] = CGRect(x: entry.minX.fixed, y: entry.minY.fixed, width: max(0, entry.maxX.fixed - entry.minX.fixed),
                                 height: max(0, entry.maxY.fixed - entry.minY.fixed))
        }
        return shown
    }

    /// A new layout carried the strip (`drift`: the live frames' x change in `ScreenContentView.reconcile`): each scrolling
    /// closing pane moves with it; `viewShift`: the new layout's view shift, to place it again once the camera moved (nil:
    /// nothing carried).
    mutating func carry(drift: CGFloat, viewShift: CGFloat?) {
        for (pane, entry) in entries {
            var entry = entry
            if entry.scrolls, drift != 0 { Self.shiftX(&entry, by: drift) }
            entry.carriedShown = viewShift.map { shift in
                entry.scrolls ? (entry.minX.fixed + shift, entry.maxX.fixed + shift) : (entry.minX.fixed, entry.maxX.fixed)
            }
            entries[pane] = entry
        }
    }

    /// The camera took its place for the new layout (`ScreenContentView.settleCarried`): each closing pane's x sides show
    /// where they showed before the change (`shift`: the strip's view shift now). A side that rides a neighbour follows it
    /// from the next frame.
    mutating func settleCarried(stripShift shift: CGFloat) {
        for (pane, entry) in entries {
            guard let shown = entry.carriedShown else { continue }
            var entry = entry
            let offset = entry.scrolls ? shift : 0
            (entry.minX.fixed, entry.maxX.fixed) = (shown.minX - offset, shown.maxX - offset)
            entry.carriedShown = nil
            entries[pane] = entry
        }
    }

    private static func shiftX(_ entry: inout Entry, by delta: CGFloat) {
        entry.minX.fixed += delta
        entry.maxX.fixed += delta
    }

    /// Takes `pane` out (its close was taken back, or its host went): its frame now, to start its live frame from, with
    /// its sides' velocities (a side on a live neighbour moves at that neighbour's speed).
    mutating func remove(_ pane: PaneID, frames: [PaneID: AnimatedFrame]) -> AnimatedFrame? {
        guard let rect = rects(frames: frames)[pane], let entry = entries.removeValue(forKey: pane) else { return nil }
        order.removeAll { $0 == pane }
        func speed(_ side: Side, _ velocity: (AnimatedFrame) -> CGFloat) -> CGFloat {
            side.neighbours.lazy.compactMap { frames[$0] }.map(velocity).first ?? 0
        }
        var frame = AnimatedFrame(rect)
        let vMinX = speed(entry.minX) { $0.x.velocity + $0.width.velocity }, vMaxX = speed(entry.maxX) { $0.x.velocity }
        let vMinY = speed(entry.minY) { $0.y.velocity + $0.height.velocity }, vMaxY = speed(entry.maxY) { $0.y.velocity }
        frame.x.velocity = vMinX
        frame.width.velocity = vMaxX - vMinX
        frame.y.velocity = vMinY
        frame.height.velocity = vMaxY - vMinY
        return frame
    }

    /// Drops a pane whose host went (it is no longer retired on this screen).
    mutating func drop(_ pane: PaneID) {
        entries[pane] = nil
        order.removeAll { $0 == pane }
    }
}
