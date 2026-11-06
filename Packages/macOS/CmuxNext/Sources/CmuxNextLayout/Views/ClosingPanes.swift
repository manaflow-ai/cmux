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
    private let rules = ClosingPanesRules()
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
    /// nil when nothing was carried. It waits for the change's cameras (``settle(frames:row:)``).
    mutating func begin(_ pane: PaneID, shown: CGRect, before: ScreenGeometry, kept: Set<DividerHandleView.Kind>, maxGap: CGFloat, rank: Int,
                        viewShift: CGFloat?) {
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
        guard rules.begin(id, shown: Self.edges(shown), panes: panes, handles: handles, maxGap: maxGap, viewShift: viewShift) else { return }
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
        load(frames, row: row)
        return Set(rules.settle().compactMap { panesByNumber[$0] })
    }

    /// Where every closing pane shows this frame, from the live panes' presented frames (`frames`, the screen's springs)
    /// and where the row columns' scrolls are and rest (`row`). A side whose neighbours are all gone (closed and landed, or
    /// taken out) keeps where they last were.
    mutating func rects(frames: [PaneID: AnimatedFrame], row: (ColumnID) -> Travel?) -> [PaneID: CGRect] { // perf-hot: 4ms motion-frame
        load(frames, row: row)
        let byNumber = panesByNumber
        var shown: [PaneID: CGRect] = [:]
        shown.reserveCapacity(entries.count)
        rules.rects { number, rect in
            guard let pane = byNumber[number] else { return }
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
    /// its sides' velocities (a side on a live neighbour moves at that neighbour's speed).
    mutating func remove(_ pane: PaneID, frames: [PaneID: AnimatedFrame]) -> AnimatedFrame? {
        entries[pane] = nil
        load(frames, row: { _ in nil })
        guard let number = paneNumbers[pane], let taken = rules.remove(number) else { return nil }
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

    private static func edges(_ rect: CGRect) -> ClosingPanesRules.Edges { ClosingPanesRules.Edges(rect) }

    /// Gives the rules the live panes' frames they may read (the panes they have a number for) and where the closing
    /// panes' row columns' scrolls are and rest (each column once), with no array of its own: a close frame allocates
    /// only the answer (`ClosingPanesFrameAllocationTests`).
    private func load(_ frames: [PaneID: AnimatedFrame], row: (ColumnID) -> Travel?) { // perf-hot: 4ms motion-frame
        let numbers = paneNumbers, entries = entries, columns = columnNumbers
        rules.load(frames: { add in
            for (pane, frame) in frames {
                guard let number = numbers[pane] else { continue }
                let moving = frame.rect != frame.targetRect || frame.x.velocity != 0 || frame.y.velocity != 0
                    || frame.width.velocity != 0 || frame.height.velocity != 0
                add(ClosingPanesRules.FrameFact(id: number, now: Self.edges(frame.rect), target: Self.edges(frame.targetRect), moving: moving,
                                                vx: frame.x.velocity, vy: frame.y.velocity, vw: frame.width.velocity, vh: frame.height.velocity))
            }
        }, rows: { add in
            for index in entries.indices {
                guard let column = entries[index].value.rowColumn,
                      !entries[entries.startIndex..<index].contains(where: { $0.value.rowColumn == column }),
                      let number = columns[column], let travel = row(column) else { continue }
                add(ClosingPanesRules.RowTravel(column: number, now: travel.now, target: travel.target))
            }
        })
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
