import CoreGraphics

// The rules of ``ClosingPanes`` over plain numbers: the screen's geometry, the live panes' frames and the row columns'
// scrolls go in as the values these rules read (``ClosingPanes`` gathers them), with each pane, scroll area and row
// column named by a number the wrapper hands out, so the same rules run in cmux-layout-reducer (`closing_panes`) over
// the same inputs. The fixture `cmux-tui/crates/cmux-layout-reducer/tests/data/closing_panes_corpus.txt` holds their
// answers for seeded scripts of closes; `ClosingPanesCorpusTests` (Swift) and `closing_panes_corpus` (Rust) both check
// against it, so the Rust port is proven equal before the app calls it (RUST MIGRATION, swift-logic owner, step A).
//
// Each body is the former ``ClosingPanes`` body with the geometry reads replaced by inputs, in the same order of
// operations: a rect's sides are the ones CoreGraphics read from it (``Edges``), and a rect this file makes is
// `(x, y, max(0, maxX - x), max(0, maxY - y))`, whose sides are `x` and `x + width`.
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

        /// The sides of a rect these rules made (`x`, `y`, `width >= 0`, `height >= 0`).
        init(_ rect: Placed) {
            self.init(minX: rect.x, maxX: rect.x + rect.width, minY: rect.y, maxY: rect.y + rect.height)
        }
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

    /// A live pane's frame this frame: its presented sides, its target sides, whether its spring moves and its velocities.
    struct FrameFact: Equatable {
        var id: UInt64
        var now: Edges
        var target: Edges
        var moving: Bool
        var vx: CGFloat
        var vy: CGFloat
        var vw: CGFloat
        var vh: CGFloat
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
    }

    /// Where a taken-back close starts and its sides' velocities (``ClosingPanes/remove(_:frames:)``).
    struct Taken: Equatable {
        var rect: Placed
        var vx: CGFloat
        var vw: CGFloat
        var vy: CGFloat
        var vh: CGFloat
    }

    /// One side of a closing pane (``ClosingPanes/Side``).
    struct Side: Equatable {
        var neighbours: [UInt64]
        var gap: CGFloat
        var fixed: CGFloat
        var start: CGFloat?
        var end: CGFloat?
    }

    struct Travel: Equatable {
        var start: CGFloat
        var target: CGFloat
    }

    struct Shown: Equatable {
        var minX: CGFloat
        var maxX: CGFloat
    }

    /// One closing pane (``ClosingPanes/Entry``, less what only the wrapper reads).
    struct Entry: Equatable {
        var minX: Side
        var maxX: Side
        var minY: Side
        var maxY: Side
        var scrolls: Bool
        var rowColumn: UInt64
        var carriedShown: Shown?
        var rowTravel: Travel?
    }

    private(set) var entries: [UInt64: Entry] = [:]
    private(set) var order: [UInt64] = []
    private(set) var awaiting: Set<UInt64> = []

    var isEmpty: Bool { entries.isEmpty }
    var hasAwaiting: Bool { !awaiting.isEmpty }

    // MARK: Swift's comparisons, as the former bodies used them

    /// `Swift.min(x, y)`.
    static func minimum(_ x: CGFloat, _ y: CGFloat) -> CGFloat { y < x ? y : x }
    /// `Swift.max(x, y)`.
    static func maximum(_ x: CGFloat, _ y: CGFloat) -> CGFloat { y >= x ? y : x }
    /// `Sequence.min()`.
    static func least(_ values: [CGFloat]) -> CGFloat? {
        guard var result = values.first else { return nil }
        for value in values.dropFirst() where value < result { result = value }
        return result
    }

    /// `Sequence.max()`.
    static func most(_ values: [CGFloat]) -> CGFloat? {
        guard var result = values.first else { return nil }
        for value in values.dropFirst() where result < value { result = value }
        return result
    }

    // MARK: The rules

    /// ``ClosingPanes/begin(_:shown:before:kept:maxGap:rank:viewShift:)``: `panes` are the layout it left, in ascending
    /// pane order; `handles` its handles. Returns whether the pane was in that layout (it starts closing).
    @discardableResult
    mutating func begin(_ pane: UInt64, shown: Edges, panes: [PaneFact], handles: [HandleFact], maxGap: CGFloat,
                        viewShift: CGFloat?) -> Bool {
        guard let own = panes.first(where: { $0.id == pane }) else { return false }
        let rest = own.edges
        var lead: [(UInt64, CGFloat)] = [], trail: [(UInt64, CGFloat)] = [], top: [(UInt64, CGFloat)] = [], bottom: [(UInt64, CGFloat)] = []
        let scrolls = own.scrolls, area = own.area, rowColumn = own.rowColumn
        for other in panes where other.id != pane && other.scrolls == scrolls {
            let was = other.edges
            if Self.minimum(was.maxY, rest.maxY) - Self.maximum(was.minY, rest.minY) > 1, other.area == area {
                let gapBefore = rest.minX - was.maxX, gapAfter = was.minX - rest.maxX
                if gapBefore >= -0.5, gapBefore <= maxGap { lead.append((other.id, Self.maximum(0, gapBefore))) }
                if gapAfter >= -0.5, gapAfter <= maxGap { trail.append((other.id, Self.maximum(0, gapAfter))) }
            }
            if Self.minimum(was.maxX, rest.maxX) - Self.maximum(was.minX, rest.minX) > 1, other.rowColumn == rowColumn {
                let gapAbove = rest.minY - was.maxY, gapBelow = was.minY - rest.maxY
                if gapAbove >= -0.5, gapAbove <= maxGap { top.append((other.id, Self.maximum(0, gapAbove))) }
                if gapBelow >= -0.5, gapBelow <= maxGap { bottom.append((other.id, Self.maximum(0, gapBelow))) }
            }
        }
        func handleStays(from lo: CGFloat, to hi: CGFloat, horizontal: Bool) -> Bool? {
            var stays: Bool?
            let across = horizontal ? (rest.minY, rest.maxY) : (rest.minX, rest.maxX)
            for handle in handles {
                let eligible = switch handle.kind {
                case .split: handle.fixedSplit != scrolls && (handle.area != 0 ? handle.area : area) == area
                case .columnEdge: !handle.docked == scrolls
                case .rowEdge: handle.column == rowColumn
                }
                guard eligible else { continue }
                let along = handle.horizontal ? handle.midX : handle.midY
                let cross = handle.horizontal ? (handle.hit.minY, handle.hit.maxY) : (handle.hit.minX, handle.hit.maxX)
                guard handle.horizontal == horizontal, along >= lo - 0.5, along <= hi + 0.5,
                      Self.minimum(cross.1, across.1) - Self.maximum(cross.0, across.0) > 1 else { continue }
                stays = stays == true || handle.kept
            }
            return stays
        }
        func widest(_ found: [(UInt64, CGFloat)]) -> CGFloat { Self.most(found.map(\.1)) ?? 0 }
        let keepsMinX = !lead.isEmpty && (handleStays(from: rest.minX - widest(lead), to: rest.minX, horizontal: true) ?? !trail.isEmpty)
        let keepsMaxX = !trail.isEmpty && (handleStays(from: rest.maxX, to: rest.maxX + widest(trail), horizontal: true) ?? false)
        let keepsMinY = !top.isEmpty && (handleStays(from: rest.minY - widest(top), to: rest.minY, horizontal: false) ?? !bottom.isEmpty)
        let keepsMaxY = !bottom.isEmpty && (handleStays(from: rest.maxY, to: rest.maxY + widest(bottom), horizontal: false) ?? false)
        func side(_ found: [(UInt64, CGFloat)], keepsGap: Bool, at value: CGFloat) -> Side {
            Side(neighbours: found.map(\.0), gap: keepsGap ? Self.least(found.map(\.1)) ?? 0 : 0, fixed: value)
        }
        entries[pane] = Entry(minX: side(lead, keepsGap: keepsMinX, at: shown.minX), maxX: side(trail, keepsGap: keepsMaxX, at: shown.maxX),
                              minY: side(top, keepsGap: keepsMinY, at: shown.minY), maxY: side(bottom, keepsGap: keepsMaxY, at: shown.maxY),
                              scrolls: scrolls, rowColumn: rowColumn,
                              carriedShown: viewShift.map { scrolls ? Shown(minX: shown.minX + $0, maxX: shown.maxX + $0) : Shown(minX: shown.minX, maxX: shown.maxX) })
        order.removeAll { $0 == pane }
        order.append(pane)
        awaiting.insert(pane)
        return true
    }

    /// ``ClosingPanes/settle(frames:row:)``.
    mutating func settle(frames: [FrameFact], rows: [RowTravel]) -> Set<UInt64> {
        defer { awaiting = [] }
        for pane in awaiting {
            guard var entry = entries[pane], entry.rowColumn != 0,
                  entry.minY.neighbours.isEmpty != entry.maxY.neighbours.isEmpty, let travel = Self.row(entry.rowColumn, rows),
                  abs(travel.target - travel.now) >= 0.5 else { continue }
            entry.rowTravel = Travel(start: travel.now, target: travel.target)
            entries[pane] = entry
        }
        return still(awaiting, frames: frames)
    }

    /// ``ClosingPanes/rects(frames:row:)``: each closing pane's frame, in the order they were placed.
    mutating func rects(frames: [FrameFact], rows: [RowTravel]) -> [(UInt64, Placed)] {
        var shown: [UInt64: Placed] = [:], rests: [UInt64: Placed] = [:], placed: [(UInt64, Placed)] = []
        for pane in order.reversed() {
            guard var entry = entries[pane] else { continue }
            func facing(_ neighbour: UInt64, _ edge: (Edges) -> CGFloat) -> CGFloat? {
                Self.frame(neighbour, frames).map { edge($0.now) } ?? shown[neighbour].map { edge(Edges($0)) }
            }
            func restingEdge(_ neighbour: UInt64, _ edge: (Edges) -> CGFloat) -> CGFloat? {
                Self.frame(neighbour, frames).map { edge($0.target) } ?? rests[neighbour].map { edge(Edges($0)) }
            }
            func place(_ side: inout Side, slowest: ([CGFloat]) -> CGFloat?, edge: (Edges) -> CGFloat, sign: CGFloat) -> CGFloat? {
                if let value = slowest(side.neighbours.compactMap({ facing($0, edge) })) { side.fixed = value + sign * side.gap }
                if side.start == nil { side.start = side.fixed }
                return slowest(side.neighbours.compactMap { restingEdge($0, edge) }).map { $0 + sign * side.gap }
            }
            func collapse(_ free: inout Side, toward rider: inout Side, rest: CGFloat?, travel: inout Travel?, scroll: RowTravel?) {
                guard free.neighbours.isEmpty, !rider.neighbours.isEmpty else { return }
                let end = rest ?? rider.fixed
                let rescrolled = travel.map { travel in scroll.map { abs($0.target - travel.target) >= 0.5 } ?? false } ?? false
                if rescrolled || free.end.map({ abs($0 - end) >= 0.5 }) == true {
                    (free.start, rider.start) = (free.fixed, rider.fixed)
                    if let scroll, travel != nil { travel = Travel(start: scroll.now, target: scroll.target) }
                }
                free.end = end
                guard let freeStart = free.start else { return }
                var done: CGFloat?
                if let rest, let riderStart = rider.start, abs(rest - riderStart) >= 0.5 {
                    done = Self.minimum(1, Self.maximum(0, (rider.fixed - riderStart) / (rest - riderStart)))
                } else if let travel, let scroll {
                    let length = travel.target - travel.start
                    done = abs(length) < 0.5 ? 1 : Self.minimum(1, Self.maximum(0, (scroll.now - travel.start) / length))
                }
                guard let done else { return }
                free.fixed = freeStart + (end - freeStart) * done
            }
            func resting(_ side: Side, _ own: CGFloat?, opposite: Side, _ other: CGFloat?) -> CGFloat {
                own ?? (side.neighbours.isEmpty && !opposite.neighbours.isEmpty ? other ?? opposite.fixed : side.fixed)
            }
            let restMinX = place(&entry.minX, slowest: Self.least, edge: \.maxX, sign: 1)
            let restMaxX = place(&entry.maxX, slowest: Self.most, edge: \.minX, sign: -1)
            let restMinY = place(&entry.minY, slowest: Self.least, edge: \.maxY, sign: 1)
            let restMaxY = place(&entry.maxY, slowest: Self.most, edge: \.minY, sign: -1)
            let scroll = entry.rowColumn != 0 ? Self.row(entry.rowColumn, rows) : nil
            var none: Travel?
            collapse(&entry.maxX, toward: &entry.minX, rest: restMinX, travel: &none, scroll: nil)
            collapse(&entry.minX, toward: &entry.maxX, rest: restMaxX, travel: &none, scroll: nil)
            collapse(&entry.maxY, toward: &entry.minY, rest: restMinY, travel: &entry.rowTravel, scroll: scroll)
            collapse(&entry.minY, toward: &entry.maxY, rest: restMaxY, travel: &entry.rowTravel, scroll: scroll)
            entries[pane] = entry
            let rect = Placed(x: entry.minX.fixed, y: entry.minY.fixed, width: Self.maximum(0, entry.maxX.fixed - entry.minX.fixed),
                              height: Self.maximum(0, entry.maxY.fixed - entry.minY.fixed))
            shown[pane] = rect
            placed.append((pane, rect))
            let x0 = resting(entry.minX, restMinX, opposite: entry.maxX, restMaxX), x1 = resting(entry.maxX, restMaxX, opposite: entry.minX, restMinX)
            let y0 = resting(entry.minY, restMinY, opposite: entry.maxY, restMaxY), y1 = resting(entry.maxY, restMaxY, opposite: entry.minY, restMinY)
            rests[pane] = Placed(x: x0, y: y0, width: Self.maximum(0, x1 - x0), height: Self.maximum(0, y1 - y0))
        }
        return placed
    }

    /// ``ClosingPanes/carry(drift:viewShift:)``.
    mutating func carry(drift: CGFloat, viewShift: CGFloat?) {
        for (pane, entry) in entries {
            var entry = entry
            if entry.scrolls, drift != 0 { Self.shiftX(&entry, by: drift) }
            entry.carriedShown = viewShift.map { shift in
                entry.scrolls ? Shown(minX: entry.minX.fixed + shift, maxX: entry.maxX.fixed + shift)
                    : Shown(minX: entry.minX.fixed, maxX: entry.maxX.fixed)
            }
            entries[pane] = entry
        }
    }

    /// ``ClosingPanes/settleCarried(stripShift:)``.
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

    /// ``ClosingPanes/shiftY(inRowColumn:by:)``.
    mutating func shiftY(inRowColumn column: UInt64, by delta: CGFloat) {
        for (pane, entry) in entries where entry.rowColumn == column {
            var entry = entry
            Self.move(&entry.minY, to: entry.minY.fixed + delta)
            Self.move(&entry.maxY, to: entry.maxY.fixed + delta)
            entries[pane] = entry
        }
    }

    /// ``ClosingPanes/remove(_:frames:)``.
    mutating func remove(_ pane: UInt64, frames: [FrameFact]) -> Taken? {
        guard let entry = entries.removeValue(forKey: pane) else { return nil }
        order.removeAll { $0 == pane }
        awaiting.remove(pane)
        let rect = Placed(x: entry.minX.fixed, y: entry.minY.fixed, width: Self.maximum(0, entry.maxX.fixed - entry.minX.fixed),
                          height: Self.maximum(0, entry.maxY.fixed - entry.minY.fixed))
        let edges = Edges(rect)
        func speed(_ side: Side, at value: CGFloat, edge: (Edges) -> CGFloat, _ velocity: (FrameFact) -> CGFloat) -> CGFloat {
            let live = side.neighbours.compactMap { Self.frame($0, frames) }
            guard var best = live.first else { return 0 }
            for frame in live.dropFirst() where abs(edge(frame.now) - value) < abs(edge(best.now) - value) { best = frame }
            return velocity(best)
        }
        let vMinX = speed(entry.minX, at: edges.minX - entry.minX.gap, edge: \.maxX) { $0.vx + $0.vw }
        let vMaxX = speed(entry.maxX, at: edges.maxX + entry.maxX.gap, edge: \.minX) { $0.vx }
        let vMinY = speed(entry.minY, at: edges.minY - entry.minY.gap, edge: \.maxY) { $0.vy + $0.vh }
        let vMaxY = speed(entry.maxY, at: edges.maxY + entry.maxY.gap, edge: \.minY) { $0.vy }
        return Taken(rect: rect, vx: vMinX, vw: vMaxX - vMinX, vy: vMinY, vh: vMaxY - vMinY)
    }

    /// ``ClosingPanes/drop(_:)``.
    mutating func drop(_ pane: UInt64) {
        entries[pane] = nil
        order.removeAll { $0 == pane }
        awaiting.remove(pane)
    }

    private func still(_ closing: Set<UInt64>, frames: [FrameFact]) -> Set<UInt64> {
        func neighbours(_ entry: Entry) -> [UInt64] { entry.minX.neighbours + entry.maxX.neighbours + entry.minY.neighbours + entry.maxY.neighbours }
        var covered = Set(entries.compactMap { pane, entry in
            !closing.contains(pane) || entry.rowTravel != nil || neighbours(entry).contains { Self.frame($0, frames)?.moving ?? false } ? pane : nil
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

    private static func frame(_ id: UInt64, _ frames: [FrameFact]) -> FrameFact? { frames.first { $0.id == id } }
    private static func row(_ column: UInt64, _ rows: [RowTravel]) -> RowTravel? { rows.first { $0.column == column } }

    private static func shiftX(_ entry: inout Entry, by delta: CGFloat) {
        move(&entry.minX, to: entry.minX.fixed + delta)
        move(&entry.maxX, to: entry.maxX.fixed + delta)
    }

    private static func move(_ side: inout Side, to value: CGFloat) {
        side.start = side.start.map { $0 + value - side.fixed }
        side.end = side.end.map { $0 + value - side.fixed }
        side.fixed = value
    }
}
