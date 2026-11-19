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
    /// The panes on this tree's left edge, top to bottom.
    var leftEdgePaneIDs: [PaneID] {
        switch self {
        case .leaf(let pane): [pane]
        case .split(_, _, .right, _, let a, _): a.leftEdgePaneIDs
        case .split(_, _, .down, _, let a, let b): a.leftEdgePaneIDs + b.leftEdgePaneIDs
        case .stack(let panes, _): panes
        case .unknown: []
        }
    }

    /// The panes directly right of `pane` in this tree, top to bottom: the left edge of the right half of the
    /// nearest side-by-side split that has `pane` on the right edge of its left half. Empty when `pane` is on
    /// the tree's own right edge; nil when the tree does not hold `pane`.
    func paneIDs(rightOf pane: PaneID) -> [PaneID]? {
        switch self {
        case .leaf(let leaf): return leaf == pane ? [] : nil
        case .stack(let panes, _): return panes.contains(pane) ? [] : nil
        case .unknown: return nil
        case .split(_, _, let direction, _, let a, let b):
            guard let inLeft = a.paneIDs(rightOf: pane) else { return b.paneIDs(rightOf: pane) }
            return inLeft.isEmpty && direction == .right ? b.leftEdgePaneIDs : inLeft
        }
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
    /// (``LayoutNode/paneIDs(rightOf:)``), else, for a pane on its column's right edge, the left edge of the next
    /// column when that one scrolls (a dock never takes another pane's tabs). Empty when nothing is there.
    func paneIDs(rightOf pane: PaneID) -> [PaneID] {
        let drawn = drawnColumns
        guard !drawn.isEmpty else { return layout.paneIDs(rightOf: pane) ?? [] }
        guard let index = drawn.firstIndex(where: { $0.layout.paneIDs.contains(pane) }) else { return [] }
        if let inside = drawn.dropFirst(index).first?.layout.paneIDs(rightOf: pane), !inside.isEmpty { return inside }
        guard let next = drawn.dropFirst(index + 1).first, next.dock == nil else { return [] }
        return next.layout.leftEdgePaneIDs
    }
}
