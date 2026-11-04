import CoreGraphics
import CmuxNextDesign

/// FRAME OWNER REFACTOR S3c: the panes a springing close took out
/// of one screen, each still shown with only its own ground (`PaneHostView.showClosingGround`) on the space its
/// neighbours, or its row column's scroll, have not covered yet.
///
/// A closing pane has no motion of its own: in each frame its rect is a function of its neighbours' frames and of its row
/// column's scroll, so the owners of the motion are the neighbours' springs and that scroll's. Each side a neighbour closes
/// over sits on the slowest neighbour's facing edge on that side (the leading edge on the smallest trailing edge beside it,
/// the trailing edge on the largest leading edge): nothing between the closing pane and any of its neighbours shows the
/// shell, and where a faster neighbour has passed over it, that live pane draws above it (closing hosts stack under every
/// live host, `ScreenContentView.ensureStacking`). A side keeps the gap it had to its neighbours where the resize handle in
/// that gap stays in the new layout, and covers the gap where that handle goes (the one between the pane and the panes that
/// take its place; FRAME OWNER S3d): the gap a person sees during the close is the kept handle's, with the handle in its
/// middle in every frame, and the pane rests at zero size where its neighbours meet. A side whose neighbour closed too
/// (after it) rides that closing pane's facing edge, and rests where that pane rests. A side with no neighbour (the screen's
/// edge, a docked column's side), opposite one on a neighbour, travels to where that side rests by the share of the motion
/// that covers the pane's place: its neighbour's travel, else the travel of its row column's scroll (the camera that springs
/// back when a scrolling column's last row closes). So the pane rests at zero size (nothing for the landing to take away in
/// one frame); with neither, it stays where it showed. The strip's camera needs no share: a column's removal clamps it at
/// once and the view carries the panes from where they showed (`ColumnScrollReducer`), so the last column's neighbour
/// moves. Chrome's tab close does the same: the closing tab shrinks to zero width on the strip's own animation.
/// The host goes when the motion lands (`ScreenContentView.releaseClosing`); a close taken back starts the pane's live
/// frame from where it shows, with its neighbours' velocities.
struct ClosingPanes {
    /// One side of a closing pane: the panes across it in the layout it left, the gap it keeps to them, and where it
    /// stands when none of them is on the screen (its fixed place, or where they last were).
    struct Side {
        let neighbours: [PaneID]
        let gap: CGFloat
        var fixed: CGFloat
        /// Where it stood in the first frame it was placed, or when its travel last started again: the start of its travel.
        var start: CGFloat?
        /// A free side's travel end as of its start (where the side opposite rests): a change that moves it starts the
        /// travel again from where the sides show (``rects(frames:row:)``).
        var end: CGFloat?
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
        /// The travel of its row column's scroll from where it was when its close began (``settle(frames:row:)``), or when
        /// that scroll last took another target (``rects(frames:row:)``); nil when it does not move or no y side collapses on
        /// it (one side with neighbours, the other with none).
        var rowTravel: (start: CGFloat, target: CGFloat)?
    }

    /// Where a row column's scroll is and where it rests.
    typealias Travel = (now: CGFloat, target: CGFloat)

    private(set) var entries: [PaneID: Entry] = [:]
    /// The order the panes closed in. Each frame places them from the last to close back to the first: a pane borders only
    /// panes that were live at its close, so no closing pane rides one that closed before it, and a side on one that closed
    /// after it reads where that pane shows in this frame (two closes in a row leave no shell between them).
    private var order: [PaneID] = []
    /// The panes this change began closing: they wait for the cameras the change sets (``settle(frames:row:)``).
    private var awaiting: Set<PaneID> = []

    var isEmpty: Bool { entries.isEmpty }
    /// Whether panes this change began closing wait for its cameras (`ScreenContentView.settleClosing`).
    var hasAwaiting: Bool { !awaiting.isEmpty }

    /// The resize handles of `geometry`: its split dividers, column edges and row edges.
    static func handles(of geometry: ScreenGeometry) -> Set<DividerHandleView.Kind> {
        var kinds = Set<DividerHandleView.Kind>()
        for divider in geometry.dividers { kinds.insert(.split(divider.id)) }
        for edge in geometry.columnEdges { kinds.insert(.columnEdge(edge.column)) }
        for edge in geometry.rowEdges { kinds.insert(.rowEdge(edge.column, edge.upper)) }
        return kinds
    }

    /// Starts `pane` closing. `shown`: where it shows, in the new layout's coordinates; `before`: the layout it left (its
    /// neighbours, the gaps beside them and the handles in those gaps); `kept`: the new layout's handles (``handles(of:)``);
    /// `maxGap`: the widest gap between two neighbours (a column gap); `rank`: its stacking rank at the close; `viewShift`:
    /// the strip's view shift in the new layout before the camera moves (what ``settleCarried(stripShift:)`` measures from),
    /// nil when nothing was carried. It waits for the change's cameras (``settle(frames:row:)``).
    mutating func begin(_ pane: PaneID, shown: CGRect, before: ScreenGeometry, kept: Set<DividerHandleView.Kind>, maxGap: CGFloat, rank: Int,
                        viewShift: CGFloat?) {
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
        /// Whether the handle in the gap beside the pane from `lo` to `hi` along `axis` stays in the new layout; nil when no
        /// handle of the pane's space (the strip or a dock, its scroll area, its row column) is there.
        func handleStays(from lo: CGFloat, to hi: CGFloat, axis: SplitAxis) -> Bool? {
            var stays: Bool?
            let across = axis == .horizontal ? (rest.minY, rest.maxY) : (rest.minX, rest.maxX)
            func consider(_ kind: DividerHandleView.Kind, _ handleAxis: SplitAxis, _ hit: CGRect) {
                let along = handleAxis == .horizontal ? hit.midX : hit.midY
                let cross = handleAxis == .horizontal ? (hit.minY, hit.maxY) : (hit.minX, hit.maxX)
                guard handleAxis == axis, along >= lo - 0.5, along <= hi + 0.5, min(cross.1, across.1) - max(cross.0, across.0) > 1 else { return }
                stays = stays == true || kept.contains(kind)
            }
            for divider in before.dividers where before.fixedSplits.contains(divider.id) != scrolls
                && (before.scrollAreaOfSplit[divider.id] ?? area) == area {
                consider(.split(divider.id), divider.axis, divider.hitFrame)
            }
            for edge in before.columnEdges where (edge.dockEdge == nil) == scrolls {
                consider(.columnEdge(edge.column), edge.axis, edge.hitFrame)
            }
            for edge in before.rowEdges where edge.column == rowColumn {
                consider(.rowEdge(edge.column, edge.upper), .vertical, edge.hitFrame)
            }
            return stays
        }
        func widest(_ found: [(PaneID, CGFloat)]) -> CGFloat { found.map(\.1).max() ?? 0 }
        // A side keeps its gap where the handle in it stays. With no handle there, the leading side keeps it when the
        // trailing side has neighbours too (they meet where it rests).
        let keepsMinX = !lead.isEmpty && (handleStays(from: rest.minX - widest(lead), to: rest.minX, axis: .horizontal) ?? !trail.isEmpty)
        let keepsMaxX = !trail.isEmpty && (handleStays(from: rest.maxX, to: rest.maxX + widest(trail), axis: .horizontal) ?? false)
        let keepsMinY = !top.isEmpty && (handleStays(from: rest.minY - widest(top), to: rest.minY, axis: .vertical) ?? !bottom.isEmpty)
        let keepsMaxY = !bottom.isEmpty && (handleStays(from: rest.maxY, to: rest.maxY + widest(bottom), axis: .vertical) ?? false)
        func side(_ found: [(PaneID, CGFloat)], keepsGap: Bool, at value: CGFloat) -> Side {
            Side(neighbours: found.map(\.0).sorted { $0.rawValue < $1.rawValue }, gap: keepsGap ? found.map(\.1).min() ?? 0 : 0, fixed: value)
        }
        entries[pane] = Entry(minX: side(lead, keepsGap: keepsMinX, at: shown.minX), maxX: side(trail, keepsGap: keepsMaxX, at: shown.maxX),
                              minY: side(top, keepsGap: keepsMinY, at: shown.minY), maxY: side(bottom, keepsGap: keepsMaxY, at: shown.maxY),
                              scrolls: scrolls, rowColumn: rowColumn, area: area, rank: rank,
                              carriedShown: viewShift.map { scrolls ? (shown.minX + $0, shown.maxX + $0) : (shown.minX, shown.maxX) })
        order.removeAll { $0 == pane }
        order.append(pane)
        awaiting.insert(pane)
    }

    /// The change's cameras are set (`ScreenContentView.syncScroll`: the strip's, with the panes it carried from where they
    /// showed, and each row column's scroll): each pane it began closing in a row column takes that scroll's travel
    /// (`row`), when one y side has neighbours and the other none (with neighbours on both they close over it). Returns the
    /// ones nothing moves over: no live neighbour on a spring (a carried one springs from here), no scroll travel, and no
    /// neighbour that closes beside them and has one. They go at once, as before S3c (their place shows what the layout
    /// rests at from the first frame).
    mutating func settle(frames: [PaneID: AnimatedFrame], row: (ColumnID) -> Travel?) -> Set<PaneID> {
        defer { awaiting = [] }
        for pane in awaiting {
            guard var entry = entries[pane], let column = entry.rowColumn,
                  entry.minY.neighbours.isEmpty != entry.maxY.neighbours.isEmpty, let travel = row(column),
                  abs(travel.target - travel.now) >= 0.5 else { continue }
            entry.rowTravel = (start: travel.now, target: travel.target)
            entries[pane] = entry
        }
        return still(awaiting, frames: frames)
    }

    /// Where every closing pane shows this frame, from the live panes' presented frames (`frames`, the screen's springs)
    /// and where the row columns' scrolls are and rest (`row`). A side whose neighbours are all gone (closed and landed, or
    /// taken out) keeps where they last were.
    mutating func rects(frames: [PaneID: AnimatedFrame], row: (ColumnID) -> Travel?) -> [PaneID: CGRect] { // perf-hot: 4ms motion-frame
        // Where each pane placed in this pass shows and rests: a pane that closed earlier rides one that closed later, read
        // from here (where it shows now, and its rest: zero size where its sides meet).
        var shown: [PaneID: CGRect] = [:], rests: [PaneID: CGRect] = [:]
        for pane in order.reversed() {
            guard var entry = entries[pane] else { continue }
            /// The facing edge of `neighbour` now: a live pane's frame, else a closing pane placed earlier in this pass (one that
            /// closed later).
            func facing(_ neighbour: PaneID, _ edge: (CGRect) -> CGFloat) -> CGFloat? {
                frames[neighbour].map { edge($0.rect) } ?? shown[neighbour].map(edge)
            }
            /// Where that edge rests: a live pane's target frame, else the rest of a closing pane placed earlier in this pass.
            func restingEdge(_ neighbour: PaneID, _ edge: (CGRect) -> CGFloat) -> CGFloat? {
                frames[neighbour].map { edge($0.targetRect) } ?? rests[neighbour].map(edge)
            }
            /// Places `side` on its slowest neighbour's facing edge; returns where it rests (that neighbour's rest).
            func place(_ side: inout Side, slowest: ([CGFloat]) -> CGFloat?, edge: (CGRect) -> CGFloat, sign: CGFloat) -> CGFloat? {
                if let value = slowest(side.neighbours.compactMap({ facing($0, edge) })) { side.fixed = value + sign * side.gap }
                if side.start == nil { side.start = side.fixed }
                return slowest(side.neighbours.compactMap { restingEdge($0, edge) }).map { $0 + sign * side.gap }
            }
            /// A side with no neighbour (`free`), opposite one that rides neighbours (`rider`): it travels from where it stood
            /// to where the rider rests (`rest`; nil: where the rider is), by the share of the motion that covers the pane's
            /// place (the rider's travel, else the share of its row column's scroll travel), so the pane rests at zero size
            /// there (no ground left for the landing to take away in one frame). A travel whose end moved (a later change, a
            /// neighbour that closed too) or whose scroll took another target starts again from where the sides and the
            /// scroll are now: the free side never jumps.
            func collapse(_ free: inout Side, toward rider: inout Side, rest: CGFloat?, travel: inout (start: CGFloat, target: CGFloat)?,
                          scroll: Travel?) {
                guard free.neighbours.isEmpty, !rider.neighbours.isEmpty else { return }
                let end = rest ?? rider.fixed
                let rescrolled = travel.map { travel in scroll.map { abs($0.target - travel.target) >= 0.5 } ?? false } ?? false
                if rescrolled || free.end.map({ abs($0 - end) >= 0.5 }) == true {
                    (free.start, rider.start) = (free.fixed, rider.fixed)
                    if let scroll, travel != nil { travel = (start: scroll.now, target: scroll.target) }
                }
                free.end = end
                guard let freeStart = free.start else { return }
                var done: CGFloat?
                if let rest, let riderStart = rider.start, abs(rest - riderStart) >= 0.5 {
                    done = min(1, max(0, (rider.fixed - riderStart) / (rest - riderStart)))
                } else if let travel, let scroll {
                    let length = travel.target - travel.start
                    done = abs(length) < 0.5 ? 1 : min(1, max(0, (scroll.now - travel.start) / length))
                }
                guard let done else { return }
                free.fixed = freeStart + (end - freeStart) * done
            }
            /// Where `side` rests: where its neighbours rest (`own`), else, free opposite a rider, where the rider rests,
            /// else where it is.
            func resting(_ side: Side, _ own: CGFloat?, opposite: Side, _ other: CGFloat?) -> CGFloat {
                own ?? (side.neighbours.isEmpty && !opposite.neighbours.isEmpty ? other ?? opposite.fixed : side.fixed)
            }
            let restMinX = place(&entry.minX, slowest: { $0.min() }, edge: \.maxX, sign: 1)
            let restMaxX = place(&entry.maxX, slowest: { $0.max() }, edge: \.minX, sign: -1)
            let restMinY = place(&entry.minY, slowest: { $0.min() }, edge: \.maxY, sign: 1)
            let restMaxY = place(&entry.maxY, slowest: { $0.max() }, edge: \.minY, sign: -1)
            let scroll = entry.rowColumn.flatMap(row)
            var none: (start: CGFloat, target: CGFloat)?
            collapse(&entry.maxX, toward: &entry.minX, rest: restMinX, travel: &none, scroll: nil)
            collapse(&entry.minX, toward: &entry.maxX, rest: restMaxX, travel: &none, scroll: nil)
            collapse(&entry.maxY, toward: &entry.minY, rest: restMinY, travel: &entry.rowTravel, scroll: scroll)
            collapse(&entry.minY, toward: &entry.maxY, rest: restMaxY, travel: &entry.rowTravel, scroll: scroll)
            entries[pane] = entry
            shown[pane] = CGRect(x: entry.minX.fixed, y: entry.minY.fixed, width: max(0, entry.maxX.fixed - entry.minX.fixed),
                                 height: max(0, entry.maxY.fixed - entry.minY.fixed))
            let x0 = resting(entry.minX, restMinX, opposite: entry.maxX, restMaxX), x1 = resting(entry.maxX, restMaxX, opposite: entry.minX, restMinX)
            let y0 = resting(entry.minY, restMinY, opposite: entry.maxY, restMaxY), y1 = resting(entry.maxY, restMaxY, opposite: entry.minY, restMinY)
            rests[pane] = CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
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
            Self.move(&entry.minX, to: shown.minX - offset)
            Self.move(&entry.maxX, to: shown.maxX - offset)
            entry.carriedShown = nil
            entries[pane] = entry
        }
    }

    /// A row column stopped scrolling (`ScreenContentView.carryRowOffset`): its closing panes keep where they show.
    mutating func shiftY(inRowColumn column: ColumnID, by delta: CGFloat) {
        for (pane, entry) in entries where entry.rowColumn == column {
            var entry = entry
            Self.move(&entry.minY, to: entry.minY.fixed + delta)
            Self.move(&entry.maxY, to: entry.maxY.fixed + delta)
            entries[pane] = entry
        }
    }

    /// The panes of `closing` that nothing moves over: no live neighbour on a spring, no row scroll travel a side of
    /// theirs collapses on (``Entry/rowTravel``), and no neighbour that closes beside them and has one (the panes already
    /// closing show, so their neighbours do too). Nothing closes over them, so they go at once (``settle(frames:row:)``).
    private func still(_ closing: Set<PaneID>, frames: [PaneID: AnimatedFrame]) -> Set<PaneID> {
        func moves(_ frame: AnimatedFrame) -> Bool {
            frame.rect != frame.targetRect || [frame.x, frame.y, frame.width, frame.height].contains { $0.velocity != 0 }
        }
        func neighbours(_ entry: Entry) -> [PaneID] { entry.minX.neighbours + entry.maxX.neighbours + entry.minY.neighbours + entry.maxY.neighbours }
        var covered = Set(entries.compactMap { pane, entry in
            !closing.contains(pane) || entry.rowTravel != nil || neighbours(entry).contains { frames[$0].map(moves) ?? false } ? pane : nil
        })
        var grew = true
        while grew {
            grew = false
            for (pane, entry) in entries where !covered.contains(pane) && neighbours(entry).contains(where: covered.contains) {
                covered.insert(pane)
                grew = true
            }
        }
        return closing.subtracting(covered)
    }

    private static func shiftX(_ entry: inout Entry, by delta: CGFloat) {
        move(&entry.minX, to: entry.minX.fixed + delta)
        move(&entry.maxX, to: entry.maxX.fixed + delta)
    }

    /// Moves a side to `value` with the start of its travel (a coordinate change, not travel).
    private static func move(_ side: inout Side, to value: CGFloat) {
        side.start = side.start.map { $0 + value - side.fixed }
        side.end = side.end.map { $0 + value - side.fixed }
        side.fixed = value
    }

    /// Takes `pane` out (its close was taken back): where it shows now (its last presented sides, carried with the strip as
    /// the live frames are, so it reads no live frame a change has not carried yet), to start its live frame from, with
    /// its sides' velocities (a side on a live neighbour moves at that neighbour's speed).
    mutating func remove(_ pane: PaneID, frames: [PaneID: AnimatedFrame]) -> AnimatedFrame? {
        guard let entry = entries.removeValue(forKey: pane) else { return nil }
        order.removeAll { $0 == pane }
        awaiting.remove(pane)
        let rect = CGRect(x: entry.minX.fixed, y: entry.minY.fixed, width: max(0, entry.maxX.fixed - entry.minX.fixed),
                          height: max(0, entry.maxY.fixed - entry.minY.fixed))
        /// The velocity of the live neighbour whose facing edge places this side now (the slowest one).
        func speed(_ side: Side, at value: CGFloat, edge: (CGRect) -> CGFloat, _ velocity: (AnimatedFrame) -> CGFloat) -> CGFloat {
            let live = side.neighbours.compactMap { frames[$0] }
            return live.min { abs(edge($0.rect) - value) < abs(edge($1.rect) - value) }.map(velocity) ?? 0
        }
        var frame = AnimatedFrame(rect)
        let vMinX = speed(entry.minX, at: rect.minX - entry.minX.gap, edge: \.maxX) { $0.x.velocity + $0.width.velocity }
        let vMaxX = speed(entry.maxX, at: rect.maxX + entry.maxX.gap, edge: \.minX) { $0.x.velocity }
        let vMinY = speed(entry.minY, at: rect.minY - entry.minY.gap, edge: \.maxY) { $0.y.velocity + $0.height.velocity }
        let vMaxY = speed(entry.maxY, at: rect.maxY + entry.maxY.gap, edge: \.minY) { $0.y.velocity }
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
        awaiting.remove(pane)
    }
}
