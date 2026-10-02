public import CmuxNextLayout

/// Keyboard pane resizing and column navigation over one screen's layout.
/// Resizing moves the divider nearest the pane in the arrow's direction;
/// in columns mode a left or right
/// resize with no horizontal split in the column changes the column width.
public nonisolated enum PaneResize {
    public enum Change: Equatable, Sendable {
        case splitRatio(LayoutSplitID, Double)
        case columnWidth(LayoutColumnID, Double)
    }

    /// Default keyboard step: 5% of the split or of the viewport width.
    public static let step = 0.05

    public static func change(for pane: LayoutPaneID, direction: LayoutDirection, in layout: ScreenLayout,
                              step: Double = PaneResize.step) -> Change? {
        let axis: SplitAxis = direction == .left || direction == .right ? .horizontal : .vertical
        let delta = direction == .left || direction == .up ? -step : step
        let tree: SplitNode?
        switch layout {
        case .splits(let root): tree = root
        case .columns: tree = layout.column(containing: pane)?.root
        }
        if let tree, let (split, ratio) = nearestSplit(containing: pane, axis: axis, in: tree) {
            let clamped = min(max(ratio + delta, SplitRatio.range.lowerBound), SplitRatio.range.upperBound)
            return clamped == ratio ? nil : .splitRatio(split, clamped)
        }
        guard let column = layout.column(containing: pane) else { return nil }
        let range = ColumnWidthPreset.widthRange
        // A top or bottom dock's extent is its height: up and down move its
        // inner edge (down grows a top dock, up grows a bottom dock).
        if let edge = column.sticky?.edge, edge.isBand {
            guard axis == .vertical else { return nil }
            let grow = edge == .top ? delta : -delta
            let extent = min(max(column.width + grow, range.lowerBound), range.upperBound)
            return extent == column.width ? nil : .columnWidth(column.id, extent)
        }
        guard axis == .horizontal else { return nil }
        let width = min(max(column.width + delta, range.lowerBound), range.upperBound)
        return width == column.width ? nil : .columnWidth(column.id, width)
    }

    /// The column before (`forward == false`) or after the pane's column.
    public static func adjacentColumn(of pane: LayoutPaneID, forward: Bool, in layout: ScreenLayout) -> LayoutColumn? {
        // Visual order: a sticky column sits at its edge whatever its daemon index.
        let columns = layout.visualColumns
        guard let index = columns.firstIndex(where: { $0.root.contains(pane) }) else { return nil }
        let next = index + (forward ? 1 : -1)
        return columns.indices.contains(next) ? columns[next] : nil
    }

    /// Deepest split along `axis` that has `pane` in one of its children.
    static func nearestSplit(containing pane: LayoutPaneID, axis: SplitAxis, in node: SplitNode) -> (LayoutSplitID, Double)? {
        guard case let .split(id, nodeAxis, ratio, a, b) = node else { return nil }
        let child = a.contains(pane) ? a : b.contains(pane) ? b : nil
        guard let child else { return nil }
        if let deeper = nearestSplit(containing: pane, axis: axis, in: child) { return deeper }
        return nodeAxis == axis ? (id, ratio) : nil
    }
}
