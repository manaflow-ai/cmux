import CmuxNextDaemon

/// The columns of a screen, for ``ControlPaneInfo/column``: what "right of the chat" means to the
/// control router (ControlCaller).
extension ControlTopologyMapper {
    /// `screen`'s columns as the window draws them, left to right: left
    /// docks, the scrolling strip, right docks. Top and bottom bands span the
    /// screen and are no column. Panes side by side in one split tree are as
    /// many columns (``sideBySide(_:)``): a screen stored as one tree, and a
    /// scrolling column that holds a split to the right. They were one
    /// column, so on such a screen no pane was right of an agent's chat and
    /// each tab opened beside it made one more pane.
    static func columns(of screen: ScreenModel) -> [(panes: Set<PaneID>, dock: String?)] {
        // A floating pane (`floating-panes-v1`, the quick terminal) is shown above the layout. The daemon keeps
        // it a leaf, on the right of the pane it came from: it is no column of its own. It counts with the first
        // column of its tree (its scrolling column's), which is that pane's column in the usual two-pane case.
        let floating = Set(screen.floating.map(\.pane))
        let groups: (LayoutNode) -> [Set<PaneID>] = { layout in
            var columns = sideBySide(layout, without: floating)
            let floats = layout.paneIDs.filter(floating.contains)
            if columns.isEmpty { return floats.isEmpty ? [] : [Set(floats)] }
            columns[0] += floats
            return columns.map { Set($0) }
        }
        guard !screen.columns.isEmpty else { return groups(screen.layout).map { (panes: $0, dock: nil) } }
        let order: (ColumnSnapshot) -> Int? = { column in
            switch column.dock?.edge {
            case .left: 0
            case nil: 1
            case .right: 2
            case .top, .bottom: nil
            }
        }
        let placed = screen.columns.compactMap { column in order(column).map { (rank: $0, column: column) } }
        return placed.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .flatMap { entry -> [(panes: Set<PaneID>, dock: String?)] in
                let column = entry.element.column
                // A dock is one column whatever it holds: a tab opened beside a chat never goes into one.
                guard column.dock == nil else { return [(panes: Set(column.layout.paneIDs), dock: column.dock?.edge.rawValue)] }
                return groups(column.layout).map { (panes: $0, dock: nil) }
            }
    }

    /// `node`'s panes in the columns its splits to the right draw, left to
    /// right, with the panes of `floating` taken out of the tree first (a
    /// split that loses one side is its other side). Only splits at the top
    /// of the tree divide it: what a split down, a stack or one pane holds is
    /// one column, so a pane below another is never "right of" it.
    static func sideBySide(_ node: LayoutNode, without floating: Set<PaneID> = []) -> [[PaneID]] {
        guard let node = floating.isEmpty ? node : tiled(node, without: floating) else { return [] }
        if case .split(_, _, .right, _, let a, let b) = node { return sideBySide(a) + sideBySide(b) }
        let panes = node.paneIDs
        return panes.isEmpty ? [] : [panes]
    }

    /// `node` without the leaves of `floating`; nil when it holds nothing else.
    static func tiled(_ node: LayoutNode, without floating: Set<PaneID>) -> LayoutNode? {
        switch node {
        case .leaf(let pane):
            return floating.contains(pane) ? nil : node
        case .split(let id, let resourceID, let direction, let ratio, let a, let b):
            guard let a = tiled(a, without: floating) else { return tiled(b, without: floating) }
            guard let b = tiled(b, without: floating) else { return a }
            return .split(id: id, resourceID: resourceID, direction: direction, ratio: ratio, a: a, b: b)
        case .stack, .unknown:
            return node
        }
    }
}
