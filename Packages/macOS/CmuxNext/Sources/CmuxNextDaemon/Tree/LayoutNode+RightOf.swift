/// What is directly right of a pane, read from the daemon's layout and not from frames: the one relation the
/// control topology (`ControlPaneInfo.rightPaneIDs`, the `beside` of `system.identify`) and the app's placement
/// of a tab beside a pane no window shows (`RightColumnPlacement.Column.init(layoutRightOf:in:holds:)`) both read.
/// A window that shows the pane measures frames instead (`RightColumnPlacement.column(beside:frames:)`); for one
/// layout the two agree, as does the daemon's own `pane.neighbor.get`.
///
/// The pane the app makes beside a terminal or a chat is a split of that pane's own column, so a relation that
/// knew columns only never found it again (fleet capture of build 76840bfee0ac, 2026-11-18: three opens made
/// three browser panes side by side).
public extension LayoutNode {
    /// A pane's share of a tree's height, as fractions of it from the top: the product of the ratios of the
    /// stacked splits on its path. The layout knows no points, so a divider has no height here.
    struct VerticalSpan: Sendable, Hashable {
        public var top: Double
        public var bottom: Double

        /// The whole height.
        public static let full = VerticalSpan(top: 0, bottom: 1)

        public init(top: Double, bottom: Double) {
            self.top = top
            self.bottom = bottom
        }

        /// The upper `ratio` of this span, and the rest below it (a stacked split's `a` and `b`).
        func divided(at ratio: Double) -> (upper: VerticalSpan, lower: VerticalSpan) {
            let middle = top + (bottom - top) * min(max(ratio, 0), 1)
            return (VerticalSpan(top: top, bottom: middle), VerticalSpan(top: middle, bottom: bottom))
        }

        /// Whether the two share any height, the on-screen rule's test (`RightColumnPlacement.column(beside:
        /// frames:)`: `rect.minY < origin.maxY && rect.maxY > origin.minY`, any overlap above zero): two panes
        /// that only meet at a row edge do not overlap. The margin is for the rounding of ratio products.
        public func overlaps(_ other: VerticalSpan) -> Bool {
            top < other.bottom - 1e-9 && bottom > other.top + 1e-9
        }
    }

    /// The panes on this tree's left edge with their spans, top to bottom, when the tree takes `span`. A stack
    /// shows one pane at a time in one place: its expanded pane stands for it.
    func leftEdge(in span: VerticalSpan = .full) -> [(pane: PaneID, span: VerticalSpan)] {
        switch self {
        case .leaf(let pane): return [(pane, span)]
        case .split(_, _, .right, _, let a, _): return a.leftEdge(in: span)
        case .split(_, _, .down, let ratio, let a, let b):
            let parts = span.divided(at: ratio)
            return a.leftEdge(in: parts.upper) + b.leftEdge(in: parts.lower)
        case .stack(_, let expanded): return [(expanded, span)]
        case .unknown: return []
        }
    }

    /// The panes directly right of `pane` in this tree, top to bottom, and `pane`'s own span, when the tree
    /// takes `span`: the panes on the left edge of the right half of the nearest side-by-side split that has
    /// `pane` on the right edge of its left half, and that share height with `pane` (``VerticalSpan/overlaps(_:)``).
    /// A pane beside the split that only touches a row above or below `pane` is not right of it. No panes when
    /// `pane` is on the tree's own right edge; nil when the tree does not hold `pane` (a member of a stack is
    /// held, with the stack's span).
    func panes(rightOf pane: PaneID, in span: VerticalSpan = .full) -> (right: [PaneID], own: VerticalSpan)? {
        switch self {
        case .leaf(let leaf): return leaf == pane ? ([], span) : nil
        case .stack(let panes, _): return panes.contains(pane) ? ([], span) : nil
        case .unknown: return nil
        case .split(_, _, .right, _, let a, let b):
            guard let found = a.panes(rightOf: pane, in: span) else { return b.panes(rightOf: pane, in: span) }
            guard found.right.isEmpty else { return found }
            return (b.leftEdge(in: span).filter { $0.span.overlaps(found.own) }.map { $0.pane }, found.own)
        case .split(_, _, .down, let ratio, let a, let b):
            let parts = span.divided(at: ratio)
            return a.panes(rightOf: pane, in: parts.upper) ?? b.panes(rightOf: pane, in: parts.lower)
        }
    }

    /// ``panes(rightOf:in:)``'s panes.
    func paneIDs(rightOf pane: PaneID) -> [PaneID]? {
        panes(rightOf: pane)?.right
    }
}

public extension ScreenModel {
    /// The screen's columns as the window draws them, left to right: left docks, the scrolling strip, right
    /// docks. Top and bottom bands span the screen and are no column. Empty for a screen stored as one split tree.
    var drawnColumns: [ColumnSnapshot] {
        let rank: (ColumnSnapshot) -> Int? = { column in
            switch column.dock?.edge {
            case .left: 0
            case nil: 1
            case .right: 2
            case .top, .bottom: nil
            }
        }
        let placed = columns.compactMap { column in rank(column).map { (rank: $0, column: column) } }
        return placed.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element.column)
    }

    /// The panes directly right of `pane` on this screen, top to bottom: inside its own column's split tree
    /// (``LayoutNode/panes(rightOf:in:)``), else, for a pane on its column's right edge, the panes on the left
    /// edge of the next column that share height with it, when that column scrolls (a dock never takes another
    /// pane's tabs). Empty when nothing is there. The same panes the app measures for a pane a window shows
    /// (`RightColumnPlacement.column(beside:frames:)`: the nearest panes past its right edge that overlap its
    /// height), but for a row offset smaller than the divider between rows, which only frames know.
    ///
    /// A zoomed pane is not read: this is the layout under the zoom, so what opens beside a zoomed caller goes
    /// to the pane that is right of it when the zoom ends. A pane with no tab is a pane like any other here;
    /// the callers decide what an empty pane takes. A stack counts as one pane, its expanded one.
    func paneIDs(rightOf pane: PaneID) -> [PaneID] {
        let drawn = drawnColumns
        guard !drawn.isEmpty else { return layout.paneIDs(rightOf: pane) ?? [] }
        guard let index = drawn.firstIndex(where: { $0.layout.paneIDs.contains(pane) }),
              let inside = drawn.dropFirst(index).first?.layout.panes(rightOf: pane) else { return [] }
        if !inside.right.isEmpty { return inside.right }
        guard let next = drawn.dropFirst(index + 1).first, next.dock == nil else { return [] }
        // Columns stand side by side at one height: the pane's share of its own column is its share of the next.
        return next.layout.leftEdge().filter { $0.span.overlaps(inside.own) }.map { $0.pane }
    }
}
