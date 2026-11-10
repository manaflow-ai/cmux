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
    /// A closing pane as the screen reads it: the space it showed in and its stacking rank. Its sides and their travel are
    /// the rules' (``ClosingPanesRules``).
    struct Entry {
        /// It scrolls with the strip (not a docked pane), and the row column and scroll area it showed in.
        let scrolls: Bool
        let rowColumn: ColumnID?
        let area: SplitID?
        /// Its stacking rank when it closed (`ScreenContentView.rank`): it stays under the live hosts of that rank.
        let rank: Int
    }

    /// Where a row column's scroll is and where it rests.
    typealias Travel = (now: CGFloat, target: CGFloat)

    private(set) var entries: [PaneID: Entry] = [:]
    private var rules = ClosingPanesRules()
    /// The numbers the rules name panes, scroll areas and row columns by (given out while this value lives).
    private var paneNumbers: [PaneID: UInt64] = [:], panesByNumber: [UInt64: PaneID] = [:]
    private var splitNumbers: [SplitID: UInt64] = [:], columnNumbers: [ColumnID: UInt64] = [:]
    private var lastNumber: UInt64 = 0

    var isEmpty: Bool { entries.isEmpty }
    /// Whether panes this change began closing wait for its cameras (`ScreenContentView.settleClosing`).
    var hasAwaiting: Bool { rules.hasAwaiting }

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
    /// nil when nothing was carried; `stripShift`: `before`'s view shift at the close's camera (a docked pane's neighbours
    /// in the strip, and a strip pane's docked ones, are found across it). It waits for the change's cameras
    /// (``settle(frames:row:)``).
    mutating func begin(_ pane: PaneID, shown: CGRect, before: ScreenGeometry, kept: Set<DividerHandleView.Kind>, maxGap: CGFloat, rank: Int,
                        viewShift: CGFloat?, stripShift: CGFloat) {
        guard before.panes[pane] != nil else { return }
        var panes: [ClosingPanesRules.PaneFact] = []
        for (other, rect) in before.panes.sorted(by: { $0.key < $1.key }) {
            let id = number(of: other)
            var area: UInt64 = 0, rowColumn: UInt64 = 0
            if let split = before.scrollAreaOfPane[other] { area = number(of: split) }
            if let column = before.rowColumnOfPane[other] { rowColumn = number(of: column) }
            panes.append(ClosingPanesRules.PaneFact(id: id, edges: Self.edges(rect), scrolls: before.scrolls(pane: other), area: area,
                                                    rowColumn: rowColumn))
        }
        var handles: [ClosingPanesRules.HandleFact] = []
        func handle(_ kind: ClosingPanesRules.HandleKind, _ axis: SplitAxis, _ hit: CGRect, kept isKept: Bool) -> ClosingPanesRules.HandleFact {
            ClosingPanesRules.HandleFact(kind: kind, horizontal: axis == .horizontal, hit: Self.edges(hit), midX: hit.midX, midY: hit.midY,
                                         kept: isKept, fixedSplit: false, area: 0, docked: false, column: 0)
        }
        for divider in before.dividers {
            var fact = handle(.split, divider.axis, divider.hitFrame, kept: kept.contains(.split(divider.id)))
            fact.fixedSplit = before.fixedSplits.contains(divider.id)
            if let split = before.scrollAreaOfSplit[divider.id] { fact.area = number(of: split) }
            handles.append(fact)
        }
        for edge in before.columnEdges {
            var fact = handle(.columnEdge, edge.axis, edge.hitFrame, kept: kept.contains(.columnEdge(edge.column)))
            fact.docked = edge.dockEdge != nil
            handles.append(fact)
        }
        for edge in before.rowEdges {
            var fact = handle(.rowEdge, .vertical, edge.hitFrame, kept: kept.contains(.rowEdge(edge.column, edge.upper)))
            fact.column = number(of: edge.column)
            handles.append(fact)
        }
        let id = number(of: pane)
        guard rules.begin(id, shown: Self.edges(shown), panes: panes, handles: handles, maxGap: maxGap, viewShift: viewShift,
                          stripShift: stripShift) else { return }
        entries[pane] = Entry(scrolls: before.scrolls(pane: pane), rowColumn: before.rowColumnOfPane[pane], area: before.scrollAreaOfPane[pane],
                              rank: rank)
    }

    /// The change's cameras are set (`ScreenContentView.syncScroll`: the strip's, with the panes it carried from where they
    /// showed, and each row column's scroll): each pane it began closing in a row column takes that scroll's travel
    /// (`row`), when one y side has neighbours and the other none (with neighbours on both they close over it). Returns the
    /// ones nothing moves over: no live neighbour on a spring (a carried one springs from here), no scroll travel, and no
    /// neighbour that closes beside them and has one. They go at once, as before S3c (their place shows what the layout
    /// rests at from the first frame).
    mutating func settle(frames: [PaneID: AnimatedFrame], row: (ColumnID) -> Travel?) -> Set<PaneID> {
        let facts = frameFacts(frames, fixed: []), rows = rowTravels(row)
        let still = rules.settle(frames: facts, rows: rows)
        return Set(still.compactMap { panesByNumber[$0] })
    }

    /// Where every closing pane shows this frame, from the live panes' presented frames (`frames`, the screen's springs;
    /// `fixed`, the ones that do not scroll), where the row columns' scrolls are and rest (`row`) and where the strip's view
    /// shift is and rests (`strip`, `restStrip`). A side whose neighbours are all gone (closed and landed, or taken out)
    /// keeps where they last were.
    mutating func rects(frames: [PaneID: AnimatedFrame], fixed: Set<PaneID>, row: (ColumnID) -> Travel?, strip: CGFloat,
                        restStrip: CGFloat) -> [PaneID: CGRect] { // perf-hot: 4ms motion-frame
        let facts = frameFacts(frames, fixed: fixed), rows = rowTravels(row)
        var shown: [PaneID: CGRect] = [:]
        for (number, rect) in rules.rects(frames: facts, rows: rows, strip: strip, restStrip: restStrip) {
            guard let pane = panesByNumber[number] else { continue }
            shown[pane] = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        }
        return shown
    }

    /// A new layout carried the strip (`drift`: the live frames' x change in `ScreenContentView.reconcile`): each scrolling
    /// closing pane moves with it; `viewShift`: the new layout's view shift, to place it again once the camera moved (nil:
    /// nothing carried).
    mutating func carry(drift: CGFloat, viewShift: CGFloat?) { rules.carry(drift: drift, viewShift: viewShift) }

    /// The camera took its place for the new layout (`ScreenContentView.settleCarried`): each closing pane's x sides show
    /// where they showed before the change (`shift`: the strip's view shift now). A side that rides a neighbour follows it
    /// from the next frame.
    mutating func settleCarried(stripShift shift: CGFloat) { rules.settleCarried(stripShift: shift) }

    /// A row column stopped scrolling (`ScreenContentView.carryRowOffset`): its closing panes keep where they show.
    mutating func shiftY(inRowColumn column: ColumnID, by delta: CGFloat) {
        guard let number = columnNumbers[column] else { return }
        rules.shiftY(inRowColumn: number, by: delta)
    }

    /// Takes `pane` out (its close was taken back): where it shows now (its last presented sides, carried with the strip as
    /// the live frames are, so it reads no live frame a change has not carried yet), to start its live frame from, with
    /// its sides' velocities (a side on a live neighbour moves at that neighbour's speed; `fixed`: the live panes that do
    /// not scroll, `strip`: the strip's view shift now).
    mutating func remove(_ pane: PaneID, frames: [PaneID: AnimatedFrame], fixed: Set<PaneID>, strip: CGFloat) -> AnimatedFrame? {
        entries[pane] = nil
        let facts = frameFacts(frames, fixed: fixed)
        guard let number = paneNumbers[pane], let taken = rules.remove(number, frames: facts, strip: strip) else { return nil }
        var frame = AnimatedFrame(CGRect(x: taken.rect.x, y: taken.rect.y, width: taken.rect.width, height: taken.rect.height))
        frame.x.velocity = taken.vx
        frame.width.velocity = taken.vw
        frame.y.velocity = taken.vy
        frame.height.velocity = taken.vh
        return frame
    }

    /// Drops a pane whose host went (it is no longer retired on this screen).
    mutating func drop(_ pane: PaneID) {
        entries[pane] = nil
        if let number = paneNumbers[pane] { rules.drop(number) }
    }

    // MARK: The rules' inputs

    private static func edges(_ rect: CGRect) -> ClosingPanesRules.Edges {
        ClosingPanesRules.Edges(minX: rect.minX, maxX: rect.maxX, minY: rect.minY, maxY: rect.maxY)
    }

    /// The live panes' frames the rules may read (the panes they have a number for); `fixed`: the ones that do not scroll;
    /// `landed`: each frame on its target (where a landing puts it).
    private func frameFacts(_ frames: [PaneID: AnimatedFrame], fixed: Set<PaneID>, landed: Bool = false) -> [ClosingPanesRules.FrameFact] {
        frames.compactMap { pane, frame in
            guard let number = paneNumbers[pane] else { return nil }
            let moving = !landed && Self.hasTravel(frame)
            return ClosingPanesRules.FrameFact(id: number, now: Self.edges(landed ? frame.targetRect : frame.rect),
                                               target: Self.edges(frame.targetRect), moving: moving,
                                               vx: frame.x.velocity, vy: frame.y.velocity, vw: frame.width.velocity, vh: frame.height.velocity,
                                               scrolls: !fixed.contains(pane))
        }
    }

    /// The least way to go the rules count as a travel (`ClosingPanesRules.collapse`, `settle`): half a point.
    private static let leastTravel: CGFloat = 0.5

    /// Whether a live pane moves over a closing pane beside it: a side of it has half a point or more to go. Less is no
    /// travel for the rules (the last part of a point of an earlier motion, as when two last columns close in a row): a
    /// closing pane a pane like that "moves over" got no travel and kept its whole place until the landing took it away in
    /// one frame (352 pt, `PaneCloseCameraGroundTests`), so it goes at once, as a pane beside panes at rest does. A
    /// velocity alone is no travel: a spring on its target does not leave it (`SpringParameters.admitted`).
    private static func hasTravel(_ frame: AnimatedFrame) -> Bool {
        let now = frame.rect, rest = frame.targetRect
        return abs(rest.minX - now.minX) >= leastTravel || abs(rest.maxX - now.maxX) >= leastTravel
            || abs(rest.minY - now.minY) >= leastTravel || abs(rest.maxY - now.maxY) >= leastTravel
    }

    /// The land rule's question for the closing panes (`ScreenContentView.advancePaneAndDividerSprings`): would a landing
    /// now, which puts every live frame on its target, move a side of a closing pane more than `snap`? A closing pane's
    /// free side follows its rider's share of the rider's travel (`ClosingPanesRules.collapse`), so the part of a point a
    /// live pane has left when it lands is, on the closing pane, that part times the pane's size over the rider's travel:
    /// 22 pt of a 352 pt pane on a rider with 4 pt to go, ground the landing took away in one frame. The rules place the
    /// closing panes two times on copies, from the live frames where this frame's step put them (`frames`, not shown yet)
    /// and from the same frames on their targets, and the answer is the largest difference of a side. It falls with the
    /// live frames' way left, so the motion lands a few frames later, never not at all: a side the frames do not move is
    /// the same in both. The cameras are taken at rest (the strip's view shift `restStrip`, no row travel): they land on
    /// their own springs, and a side they move does not hold the panes' landing.
    ///
    /// What it bounds is the way from this frame's step, which is not shown, to the landing. The frame shown before is
    /// one step further away: with `snap` a quarter point, a side moves up to about 0.44 pt on the screen in the
    /// landing's frame at 120 Hz (about 0.8 pt at 60 Hz), under the one point the ground rule allows. It does not see a
    /// side the rules gave no travel (a pane like that keeps its place; `hasTravel` and
    /// `ScreenContentView.settleClosing` are what keep one from being made), and it needs the rules to be a value: the
    /// two placements run on copies.
    func landingMovesAClosingPane(frames: [PaneID: AnimatedFrame], fixed: Set<PaneID>, restStrip: CGFloat, snap: CGFloat) -> Bool { // perf-hot: 4ms motion-frame
        guard !entries.isEmpty else { return false }
        var stepped = rules, landed = rules
        let now = stepped.rects(frames: frameFacts(frames, fixed: fixed), rows: [], strip: restStrip, restStrip: restStrip)
        let then = landed.rects(frames: frameFacts(frames, fixed: fixed, landed: true), rows: [], strip: restStrip, restStrip: restStrip)
        // Both lists are in the rules' order (the same entries, the same order).
        return zip(now, then).contains { a, b in
            abs(a.1.x - b.1.x) > snap || abs(a.1.x + a.1.width - b.1.x - b.1.width) > snap
                || abs(a.1.y - b.1.y) > snap || abs(a.1.y + a.1.height - b.1.y - b.1.height) > snap
        }
    }

    /// Where the closing panes' row columns' scrolls are and rest.
    private func rowTravels(_ row: (ColumnID) -> Travel?) -> [ClosingPanesRules.RowTravel] {
        var travels: [ClosingPanesRules.RowTravel] = []
        for column in Set(entries.values.compactMap(\.rowColumn)) {
            guard let number = columnNumbers[column], let travel = row(column) else { continue }
            travels.append(ClosingPanesRules.RowTravel(column: number, now: travel.now, target: travel.target))
        }
        return travels
    }

    private mutating func number(of pane: PaneID) -> UInt64 {
        if let number = paneNumbers[pane] { return number }
        lastNumber += 1
        paneNumbers[pane] = lastNumber
        panesByNumber[lastNumber] = pane
        return lastNumber
    }

    private mutating func number(of split: SplitID) -> UInt64 {
        if let number = splitNumbers[split] { return number }
        lastNumber += 1
        splitNumbers[split] = lastNumber
        return lastNumber
    }

    private mutating func number(of column: ColumnID) -> UInt64 {
        if let number = columnNumbers[column] { return number }
        lastNumber += 1
        columnNumbers[column] = lastNumber
        return lastNumber
    }
}
