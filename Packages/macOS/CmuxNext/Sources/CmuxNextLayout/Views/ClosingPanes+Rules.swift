import CCmuxLayoutReducerFFI
import CoreGraphics

// The rules of ``ClosingPanes`` run by cmux-layout-reducer (`closing_panes`) over the app FFI's typed
// `cmux_closing_panes_*` calls: one handle per screen owns the closing panes, no JSON, and the per-frame `rects` call
// allocates nothing on either side once the buffers have grown: the live frames and row travels go into C arrays the
// handle keeps from frame to frame (``load(frames:rows:)``), and the answer is read in place. Nothing here decides: these map the values the
// wrapper read from the geometry and the live frames into the C structs and the answers back. The rules and their tests
// are in the crate (`src/closing_panes.rs`, `tests/closing_panes_corpus.rs`); `ClosingPanesCorpusTests` checks these
// calls against the same corpus the Swift rules recorded before they moved.
nonisolated struct ClosingPanesRules {
    /// A rect's sides as CoreGraphics reads them (`CGRect.minX`, `maxX`, `minY`, `maxY`).
    struct Edges: Equatable {
        var minX: CGFloat
        var maxX: CGFloat
        var minY: CGFloat
        var maxY: CGFloat

        init(minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
            self.minX = minX
            self.maxX = maxX
            self.minY = minY
            self.maxY = maxY
        }

        var c: CmuxClosingEdges { CmuxClosingEdges(min_x: Double(minX), max_x: Double(maxX), min_y: Double(minY), max_y: Double(maxY)) }

        init(_ rect: CGRect) { self.init(minX: rect.minX, maxX: rect.maxX, minY: rect.minY, maxY: rect.maxY) }
    }

    /// One pane of the layout a close left, in ascending pane order. `area` and `rowColumn`: 0 for none.
    struct PaneFact: Equatable {
        var id: UInt64
        var edges: Edges
        var scrolls: Bool
        var area: UInt64
        var rowColumn: UInt64
    }

    enum HandleKind: UInt8 {
        case split = 0
        case columnEdge = 1
        case rowEdge = 2
    }

    /// One resize handle of the layout a close left.
    struct HandleFact: Equatable {
        var kind: HandleKind
        var horizontal: Bool
        var hit: Edges
        var midX: CGFloat
        var midY: CGFloat
        var kept: Bool
        var fixedSplit: Bool
        var area: UInt64
        var docked: Bool
        var column: UInt64
    }

    /// A live pane's frame this frame.
    struct FrameFact: Equatable {
        var id: UInt64
        var now: Edges
        var target: Edges
        var moving: Bool
        var vx: CGFloat
        var vy: CGFloat
        var vw: CGFloat
        var vh: CGFloat

        var c: CmuxClosingFrame {
            CmuxClosingFrame(id: id, now: now.c, target: target.c, vx: Double(vx), vy: Double(vy), vw: Double(vw), vh: Double(vh),
                             moving: moving ? 1 : 0, reserved: (0, 0, 0, 0, 0, 0, 0))
        }
    }

    /// Where a row column's scroll is and where it rests.
    struct RowTravel: Equatable {
        var column: UInt64
        var now: CGFloat
        var target: CGFloat
    }

    struct Placed: Equatable {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat
    }

    struct Taken: Equatable {
        var rect: Placed
        var vx: CGFloat
        var vw: CGFloat
        var vy: CGFloat
        var vh: CGFloat
    }

    /// The Rust handle, freed with the last copy of this value. A copy shares it: ``ClosingPanes`` is the only owner and
    /// replaces this value whole (`ScreenContentView.releaseClosing`), never copying it.
    private final class Handle {
        let pointer: OpaquePointer
        /// The live frames and row travels of the next call, kept from frame to frame so a frame allocates none.
        var frames: [CmuxClosingFrame] = []
        var rows: [CmuxClosingRow] = []

        init() { pointer = cmux_closing_panes_new() }

        deinit { cmux_closing_panes_free(pointer) }
    }

    private let handle = Handle()

    var hasAwaiting: Bool { cmux_closing_panes_has_awaiting(handle.pointer) == 1 }
    /// The hash of the whole state (the corpus tests compare it after each call).
    var stateHash: UInt64 { cmux_closing_panes_state_hash(handle.pointer) }

    /// ``ClosingPanes/begin(_:shown:before:kept:maxGap:rank:viewShift:)``. Returns whether the pane starts closing.
    @discardableResult
    func begin(_ pane: UInt64, shown: Edges, panes: [PaneFact], handles: [HandleFact], maxGap: CGFloat, viewShift: CGFloat?) -> Bool {
        let cPanes = panes.map {
            CmuxClosingPane(id: $0.id, area: $0.area, row_column: $0.rowColumn, edges: $0.edges.c, scrolls: $0.scrolls ? 1 : 0,
                            reserved: (0, 0, 0, 0, 0, 0, 0))
        }
        let cHandles = handles.map {
            CmuxClosingHandle(hit: $0.hit.c, mid_x: Double($0.midX), mid_y: Double($0.midY), area: $0.area, column: $0.column,
                              kind: $0.kind.rawValue, horizontal: $0.horizontal ? 1 : 0, kept: $0.kept ? 1 : 0,
                              fixed_split: $0.fixedSplit ? 1 : 0, docked: $0.docked ? 1 : 0, reserved: (0, 0, 0))
        }
        var cShown = shown.c
        let code = cPanes.withUnsafeBufferPointer { cPanes in
            cHandles.withUnsafeBufferPointer { cHandles in
                cmux_closing_panes_begin(handle.pointer, pane, &cShown, cPanes.baseAddress, cPanes.count, cHandles.baseAddress,
                                         cHandles.count, Double(maxGap), viewShift == nil ? 0 : 1, Double(viewShift ?? 0))
            }
        }
        return code == 1
    }

    /// Sets the live frames and row travels that ``settle()``, ``rects(_:)`` and ``remove(_:)`` read: `frames` gives
    /// each live frame, `rows` each row column's travel, into the buffers kept from the last call.
    func load(frames: (_ add: (FrameFact) -> Void) -> Void, rows: (_ add: (RowTravel) -> Void) -> Void) { // perf-hot: 4ms motion-frame
        let handle = handle
        handle.frames.removeAll(keepingCapacity: true)
        handle.rows.removeAll(keepingCapacity: true)
        frames { handle.frames.append($0.c) }
        rows { handle.rows.append(CmuxClosingRow(column: $0.column, now: Double($0.now), target: Double($0.target))) }
    }

    /// ``ClosingPanes/settle(frames:row:)``, over the loaded frames.
    func settle() -> Set<UInt64> {
        var out = CmuxClosingIds()
        let code = withLoaded { frames, rows in
            cmux_closing_panes_settle(handle.pointer, frames.baseAddress, frames.count, rows.baseAddress, rows.count, &out)
        }
        guard code == 0, let ids = out.ids else { return [] }
        return Set(UnsafeBufferPointer(start: ids, count: out.count))
    }

    /// ``ClosingPanes/rects(frames:row:)``, over the loaded frames: each closing pane's frame, in the order they were placed,
    /// read in place from the handle's answer.
    func rects(_ each: (UInt64, Placed) -> Void) { // perf-hot: 4ms motion-frame
        var out = CmuxClosingPlacedList()
        let code = withLoaded { frames, rows in
            cmux_closing_panes_rects(handle.pointer, frames.baseAddress, frames.count, rows.baseAddress, rows.count, &out)
        }
        guard code == 0, let placed = out.placed else { return }
        for item in UnsafeBufferPointer(start: placed, count: out.count) { each(item.pane, Self.placed(item.rect)) }
    }

    /// ``ClosingPanes/remove(_:frames:)``, over the loaded frames.
    func remove(_ pane: UInt64) -> Taken? {
        var out = CmuxClosingTaken()
        let code = handle.frames.withUnsafeBufferPointer { frames in
            cmux_closing_panes_remove(handle.pointer, pane, frames.baseAddress, frames.count, &out)
        }
        guard code == 1 else { return nil }
        return Taken(rect: Self.placed(out.rect), vx: CGFloat(out.vx), vw: CGFloat(out.vw), vy: CGFloat(out.vy), vh: CGFloat(out.vh))
    }

    /// ``settle()`` with these frames and rows (the corpus replays its recorded calls through these).
    func settle(frames: [FrameFact], rows: [RowTravel]) -> Set<UInt64> {
        load(frames: { add in frames.forEach(add) }, rows: { add in rows.forEach(add) })
        return settle()
    }

    /// ``rects(_:)`` with these frames and rows.
    func rects(frames: [FrameFact], rows: [RowTravel]) -> [(UInt64, Placed)] {
        load(frames: { add in frames.forEach(add) }, rows: { add in rows.forEach(add) })
        var placed: [(UInt64, Placed)] = []
        rects { placed.append(($0, $1)) }
        return placed
    }

    /// ``remove(_:)`` with these frames.
    func remove(_ pane: UInt64, frames: [FrameFact]) -> Taken? {
        load(frames: { add in frames.forEach(add) }, rows: { _ in })
        return remove(pane)
    }

    /// ``ClosingPanes/carry(drift:viewShift:)``.
    func carry(drift: CGFloat, viewShift: CGFloat?) {
        _ = cmux_closing_panes_carry(handle.pointer, Double(drift), viewShift == nil ? 0 : 1, Double(viewShift ?? 0))
    }

    /// ``ClosingPanes/settleCarried(stripShift:)``.
    func settleCarried(stripShift shift: CGFloat) { _ = cmux_closing_panes_settle_carried(handle.pointer, Double(shift)) }

    /// ``ClosingPanes/shiftY(inRowColumn:by:)``.
    func shiftY(inRowColumn column: UInt64, by delta: CGFloat) { _ = cmux_closing_panes_shift_y(handle.pointer, column, Double(delta)) }

    /// ``ClosingPanes/drop(_:)``.
    func drop(_ pane: UInt64) { _ = cmux_closing_panes_drop(handle.pointer, pane) }

    private static func placed(_ rect: CmuxClosingRect) -> Placed {
        Placed(x: CGFloat(rect.x), y: CGFloat(rect.y), width: CGFloat(rect.width), height: CGFloat(rect.height))
    }

    private func withLoaded<Result>(_ body: (UnsafeBufferPointer<CmuxClosingFrame>, UnsafeBufferPointer<CmuxClosingRow>) -> Result) -> Result {
        handle.frames.withUnsafeBufferPointer { frames in handle.rows.withUnsafeBufferPointer { rows in body(frames, rows) } }
    }
}
