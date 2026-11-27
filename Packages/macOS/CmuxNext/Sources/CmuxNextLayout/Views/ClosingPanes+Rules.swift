import CCmuxLayoutReducerFFI
import CoreGraphics

// The rules of ``ClosingPanes`` are Rust's: cmux-layout-reducer `closing_panes` behind the app FFI's
// `cmux_closing_panes_*` (cmux-layout-reducer-ffi `closing_panes.rs`). This value owns one handle per screen and turns
// the facts ``ClosingPanes`` gathers (the screen's geometry, the live panes' frames and the row columns' scrolls, with
// each pane, scroll area and row column named by a number the wrapper hands out) into the C structs, and the answers
// back. Nothing here decides. The fixture `cmux-tui/crates/cmux-layout-reducer/tests/data/closing_panes_corpus.txt`
// (recorded from the Swift rules this replaced) holds their answers and state for seeded scripts of closes;
// `ClosingPanesCorpusTests` replays it through this value and `closing_panes_corpus` (Rust) through the crate.
//
// The handle is a reference: copies of this value share one state. ``ClosingPanes`` keeps one per screen and never
// copies it; the land rule's question (``landingMoves(frames:restStrip:snap:)``) places the panes on copies inside
// Rust.
//
// Cost: a call converts its arrays once (the live panes' frames, the row travels: a few elements per screen) and
// copies the answer out of the handle's buffer, which Rust reuses, so Rust allocates nothing per frame once its buffers
// have grown; `landingMoves` copies the state two times, as the Swift value copies did.
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
    }

    /// One pane of the layout a close left (`ScreenGeometry.panes`), in ascending pane order (the order a side lists
    /// its neighbours in). `area` and `rowColumn`: 0 for none.
    struct PaneFact: Equatable {
        var id: UInt64
        var edges: Edges
        var scrolls: Bool
        var area: UInt64
        var rowColumn: UInt64
    }

    /// `CMUX_CLOSING_HANDLE_*`.
    enum HandleKind: UInt8 {
        case split = 0
        case columnEdge = 1
        case rowEdge = 2
    }

    /// One resize handle of the layout a close left: a split divider, a column edge or a row edge.
    struct HandleFact: Equatable {
        var kind: HandleKind
        /// Its axis is `.horizontal` (a row edge's is `.vertical`).
        var horizontal: Bool
        var hit: Edges
        /// The hit frame's middle (`CGRect.midX`, `midY`).
        var midX: CGFloat
        var midY: CGFloat
        /// The new layout has it (`ClosingPanes.handles(of:)`).
        var kept: Bool
        /// A split of the fixed (unscrolled) part (`ScreenGeometry.fixedSplits`).
        var fixedSplit: Bool
        /// A split's scroll area (`ScreenGeometry.scrollAreaOfSplit`); 0 for none.
        var area: UInt64
        /// A column edge of a dock (`ColumnEdgeGeometry.dockEdge != nil`).
        var docked: Bool
        /// A row edge's column.
        var column: UInt64
    }

    /// A live pane's frame this frame: its presented sides, its target sides, whether its spring moves, its velocities and
    /// whether it scrolls with the strip (its x is in strip coordinates; a fixed pane's in the view's).
    struct FrameFact: Equatable {
        var id: UInt64
        var now: Edges
        var target: Edges
        var moving: Bool
        var vx: CGFloat
        var vy: CGFloat
        var vw: CGFloat
        var vh: CGFloat
        var scrolls: Bool = true
    }

    /// Where a row column's scroll is and where it rests.
    struct RowTravel: Equatable {
        var column: UInt64
        var now: CGFloat
        var target: CGFloat
    }

    /// A closing pane's frame this frame (or where a taken-back close starts), as a rect.
    struct Placed: Equatable {
        var x: CGFloat
        var y: CGFloat
        var width: CGFloat
        var height: CGFloat

        init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        init(_ rect: CmuxClosingRect) { self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height) }
    }

    /// Where a taken-back close starts and its sides' velocities (``ClosingPanes/remove(_:frames:fixed:strip:)``).
    struct Taken: Equatable {
        var rect: Placed
        var vx: CGFloat
        var vw: CGFloat
        var vy: CGFloat
        var vh: CGFloat
    }

    private let handle = ClosingPanesHandle()

    /// Whether panes the last change began closing wait for its cameras.
    var hasAwaiting: Bool { cmux_closing_panes_has_awaiting(handle.pointer) != 0 }

    /// The hash of the whole state (every side, travel and carry, the close order and the panes awaiting the cameras):
    /// the corpus tests compare it after each call.
    var stateHash: UInt64 { cmux_closing_panes_state_hash(handle.pointer) }

    /// ``ClosingPanes/begin(_:shown:before:kept:maxGap:rank:viewShift:stripShift:)``: `panes` are the layout it left, in
    /// ascending pane order; `handles` its handles; `stripShift` that layout's view shift at the camera of the close.
    /// Returns whether the pane was in that layout (it starts closing).
    @discardableResult
    mutating func begin(_ pane: UInt64, shown: Edges, panes: [PaneFact], handles: [HandleFact], maxGap: CGFloat,
                        viewShift: CGFloat?, stripShift: CGFloat) -> Bool {
        let cPanes = panes.map { fact in
            var p = CmuxClosingPane()
            p.id = fact.id
            p.area = fact.area
            p.row_column = fact.rowColumn
            p.edges = fact.edges.c
            p.scrolls = fact.scrolls ? 1 : 0
            return p
        }
        let cHandles = handles.map { fact in
            var h = CmuxClosingHandle()
            h.hit = fact.hit.c
            h.mid_x = Double(fact.midX)
            h.mid_y = Double(fact.midY)
            h.area = fact.area
            h.column = fact.column
            h.kind = fact.kind.rawValue
            h.horizontal = fact.horizontal ? 1 : 0
            h.kept = fact.kept ? 1 : 0
            h.fixed_split = fact.fixedSplit ? 1 : 0
            h.docked = fact.docked ? 1 : 0
            return h
        }
        var cShown = shown.c
        let code = cPanes.withUnsafeBufferPointer { panes in
            cHandles.withUnsafeBufferPointer { handles in
                cmux_closing_panes_begin(handle.pointer, pane, &cShown, panes.baseAddress, panes.count, handles.baseAddress, handles.count,
                                         Double(maxGap), viewShift == nil ? 0 : 1, Double(viewShift ?? 0), Double(stripShift))
            }
        }
        return code == 1
    }

    /// ``ClosingPanes/settle(frames:row:)``: the panes nothing moves over.
    mutating func settle(frames: [FrameFact], rows: [RowTravel]) -> Set<UInt64> {
        let cFrames = Self.c(frames), cRows = Self.c(rows)
        var out = CmuxClosingIds(ids: nil, count: 0)
        let code = cFrames.withUnsafeBufferPointer { frames in
            cRows.withUnsafeBufferPointer { rows in
                cmux_closing_panes_settle(handle.pointer, frames.baseAddress, frames.count, rows.baseAddress, rows.count, &out)
            }
        }
        guard code == CMUX_LAYOUT_REDUCER_OK, let ids = out.ids else { return [] }
        // The list borrows the handle's buffer until the next call: copied out here.
        return Set(UnsafeBufferPointer(start: ids, count: out.count))
    }

    /// ``ClosingPanes/rects(frames:fixed:row:strip:restStrip:)``: each closing pane's frame, in the order they were
    /// placed. `strip`: the strip's view shift now; `restStrip`: where it rests.
    mutating func rects(frames: [FrameFact], rows: [RowTravel], strip: CGFloat, restStrip: CGFloat) -> [(UInt64, Placed)] {
        let cFrames = Self.c(frames), cRows = Self.c(rows)
        var out = CmuxClosingPlacedList(placed: nil, count: 0)
        let code = cFrames.withUnsafeBufferPointer { frames in
            cRows.withUnsafeBufferPointer { rows in
                cmux_closing_panes_rects(handle.pointer, frames.baseAddress, frames.count, rows.baseAddress, rows.count, Double(strip),
                                         Double(restStrip), &out)
            }
        }
        guard code == CMUX_LAYOUT_REDUCER_OK, let placed = out.placed else { return [] }
        // The list borrows the handle's buffer until the next call: copied out here.
        return UnsafeBufferPointer(start: placed, count: out.count).map { ($0.pane, Placed($0.rect)) }
    }

    /// ``ClosingPanes/landingMovesAClosingPane(frames:fixed:restStrip:snap:)``: would a landing now, which puts every
    /// live frame (`frames`, where this frame's step put them) on its target, move a side of a closing pane more than
    /// `snap`? The cameras are taken at rest (`restStrip`, no row travel). Rust places the panes on two copies of the
    /// state; this one is not changed.
    func landingMoves(frames: [FrameFact], restStrip: CGFloat, snap: CGFloat) -> Bool {
        let cFrames = Self.c(frames)
        return cFrames.withUnsafeBufferPointer { frames in
            cmux_closing_panes_landing_moves(handle.pointer, frames.baseAddress, frames.count, Double(restStrip), Double(snap))
        } == 1
    }

    /// ``ClosingPanes/carry(drift:viewShift:)``.
    mutating func carry(drift: CGFloat, viewShift: CGFloat?) {
        cmux_closing_panes_carry(handle.pointer, Double(drift), viewShift == nil ? 0 : 1, Double(viewShift ?? 0))
    }

    /// ``ClosingPanes/settleCarried(stripShift:)``.
    mutating func settleCarried(stripShift shift: CGFloat) { cmux_closing_panes_settle_carried(handle.pointer, Double(shift)) }

    /// ``ClosingPanes/shiftY(inRowColumn:by:)``.
    mutating func shiftY(inRowColumn column: UInt64, by delta: CGFloat) { cmux_closing_panes_shift_y(handle.pointer, column, Double(delta)) }

    /// ``ClosingPanes/remove(_:frames:fixed:strip:)``: `strip`, the strip's view shift now.
    mutating func remove(_ pane: UInt64, frames: [FrameFact], strip: CGFloat) -> Taken? {
        let cFrames = Self.c(frames)
        var out = CmuxClosingTaken()
        let code = cFrames.withUnsafeBufferPointer { frames in
            cmux_closing_panes_remove(handle.pointer, pane, frames.baseAddress, frames.count, Double(strip), &out)
        }
        guard code == 1 else { return nil }
        return Taken(rect: Placed(out.rect), vx: out.vx, vw: out.vw, vy: out.vy, vh: out.vh)
    }

    /// ``ClosingPanes/drop(_:)``.
    mutating func drop(_ pane: UInt64) { cmux_closing_panes_drop(handle.pointer, pane) }

    private static func c(_ frames: [FrameFact]) -> [CmuxClosingFrame] {
        frames.map { fact in
            var f = CmuxClosingFrame()
            f.id = fact.id
            f.now = fact.now.c
            f.target = fact.target.c
            f.vx = Double(fact.vx)
            f.vy = Double(fact.vy)
            f.vw = Double(fact.vw)
            f.vh = Double(fact.vh)
            f.moving = fact.moving ? 1 : 0
            f.fixed = fact.scrolls ? 0 : 1
            return f
        }
    }

    private static func c(_ rows: [RowTravel]) -> [CmuxClosingRow] {
        rows.map { CmuxClosingRow(column: $0.column, now: Double($0.now), target: Double($0.target)) }
    }
}

/// Owns the `cmux_closing_panes_*` handle: made one time, freed one time when the last ``ClosingPanesRules`` copy lets
/// go. A null handle (allocation failed) answers nothing: every call returns `ERR_NULL` and no pane closes springing.
private nonisolated final class ClosingPanesHandle {
    let pointer: OpaquePointer?

    init() {
        pointer = cmux_closing_panes_new()
    }

    deinit {
        cmux_closing_panes_free(pointer)
    }
}
