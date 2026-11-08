public import CmuxNextLayout

/// Keyboard pane resizing and column navigation over one screen's layout.
///
/// One press moves one divider one step in the arrow's direction, as Ghostty's `resize_split` does, and changes only
/// the two sides of that divider (FRAME OWNER REFACTOR KEYS, lead decision 2026-11-03):
/// - A split: the deepest split along the arrow's axis that holds the pane; its ratio moves toward the arrow.
/// - A strip column (columns mode, no split along the axis): the divider is the column's right edge when a strip
///   column follows it, else its left edge (the last column). The two columns beside it trade width (an Option-drag's
///   trade): the columns after them and the strip's camera stay. One column alone moves its right edge.
/// - A side dock: its inner edge (a left dock grows with Right, a right dock shrinks with Right). A top or bottom
///   dock: its inner edge with Up and Down. A row (rows-v1): the row edge with Up and Down.
/// A press steps from the size the screen shows and stops at the size it can show (`shown`): one equal step, the part
/// step that reaches a pane's minimum or the edge of the strip the window shows, or no change at all; never a model
/// change that moves nothing.
public nonisolated enum PaneResize {
    public enum Change: Equatable, Sendable {
        case splitRatio(LayoutSplitID, Double)
        case columnWidth(LayoutColumnID, Double)
        /// Two neighbor strip columns, left then right, trade width across the divider between them.
        case columnTrade(LayoutColumnID, Double, LayoutColumnID, Double)
        /// Every row height of a rows-v1 column (permille), one row edge moved.
        case rowHeights(LayoutColumnID, [RowHeight])
    }

    /// Default keyboard step: 5% of the split or of the viewport width.
    public static let step = 0.05

    /// The change one press makes. `shown`: the sizes the screen can show (``ShownResizeRange``).
    public static func change(for pane: LayoutPaneID, direction: LayoutDirection, in layout: ScreenLayout,
                              shown: ShownResizeRange? = nil, step: Double = PaneResize.step) -> Change? {
        let axis: SplitAxis = direction == .left || direction == .right ? .horizontal : .vertical
        let delta = direction == .left || direction == .up ? -step : step
        let tree: SplitNode?
        switch layout {
        case .splits(let root): tree = root
        case .columns: tree = layout.column(containing: pane)?.tree(containing: pane)
        }
        if let tree, let (split, ratio) = nearestSplit(containing: pane, axis: axis, in: tree) {
            return stepped(ratio, by: delta, within: SplitRatio.range, shown: shown?.ratio(of: split)).map { .splitRatio(split, $0) }
        }
        guard let column = layout.column(containing: pane) else { return nil }
        // A pane in a row (rows-v1) with no vertical split of its own: up and down move its row's edge.
        if axis == .vertical, column.hasRows, column.dock?.edge.isBand != true {
            return shown?.rowHeights(moving: pane, in: column, by: delta).map { .rowHeights(column.id, $0) }
        }
        let range = ColumnWidthPreset.widthRange
        // A top or bottom dock's extent is its height: up and down move its
        // inner edge (down grows a top dock, up grows a bottom dock).
        if let edge = column.dock?.edge, edge.isBand {
            guard axis == .vertical else { return nil }
            let grow = edge == .top ? delta : -delta
            let extent = min(max(column.width + grow, range.lowerBound), range.upperBound)
            return extent == column.width ? nil : .columnWidth(column.id, extent)
        }
        guard axis == .horizontal else { return nil }
        let parts = DockStripGeometry.docks(layout.columns)
        // A side dock's inner edge: a left dock's right edge, a right dock's left edge, inside the widths it shows.
        if parts.left?.id == column.id || parts.right?.id == column.id {
            let grow = parts.right?.id == column.id ? -delta : delta
            return stepped(column.width, by: grow, within: range, shown: shown?.dockWidth(of: column)).map { .columnWidth(column.id, $0) }
        }
        let strip = parts.scrolling
        guard let index = strip.firstIndex(where: { $0.id == column.id }) else { return nil }
        guard strip.count > 1 else {
            // A screen whose only column is a dock shows it full width whatever its width (`DockStripGeometry.docks`): no
            // press moves it.
            guard strip[index].dock == nil else { return nil }
            return stepped(column.width, by: delta, within: range, shown: shown?.width(of: column)).map { .columnWidth(column.id, $0) }
        }
        let (left, right) = index + 1 < strip.count ? (strip[index], strip[index + 1]) : (strip[index - 1], strip[index])
        return shown?.trade(left, right, by: delta, in: layout).map { .columnTrade(left.id, $0.left, right.id, $0.right) }
    }

    /// `value` moved by `delta` inside `range` cut to `shown`, from where the screen shows it: a value past what the
    /// screen can show (set before, or by another client) counts as the shown limit, so the press back is a whole
    /// step. Nil when the press would change nothing on screen.
    static func stepped(_ value: Double, by delta: Double, within range: ClosedRange<Double>, shown: ClosedRange<Double>?) -> Double? {
        var lower = range.lowerBound, upper = range.upperBound
        if let shown, shown.lowerBound <= upper, shown.upperBound >= lower {
            (lower, upper) = (max(lower, shown.lowerBound), min(upper, shown.upperBound))
        }
        let current = min(max(value, lower), upper)
        let next = min(max(current + delta, lower), upper)
        return abs(next - current) < 1e-9 ? nil : next
    }

    /// One keyboard resize press on `pane` (`resizePane*`): the change ``change(for:direction:in:shown:step:)`` makes,
    /// inside what `view` shows, written to `model`. False when nothing can move that way (the caller refuses
    /// quietly); true for a pane on no screen (nothing to say).
    @MainActor
    public static func press(_ pane: LayoutPaneID, _ direction: LayoutDirection, model: LayoutModel, view: LayoutRootView) -> Bool {
        guard let screen = model.screen(containing: pane) else { return true }
        guard let change = change(for: pane, direction: direction, in: screen.layout, shown: view.shownResizeRange(ofScreenContaining: pane)) else {
            return false
        }
        // A split ratio, a width or a trade is one change, all or nothing (`EndedValues`): refused before anything moves
        // when the app cannot send all of it now (a column the daemon has not made yet).
        let values: EndedValues? = switch change {
        case .splitRatio(let split, let ratio): EndedValues([.ratio(split, ratio)])
        case .columnWidth(let column, let width): EndedValues([.width(column, width)])
        case .columnTrade(let left, let leftWidth, let right, let rightWidth): EndedValues([.width(left, leftWidth), .width(right, rightWidth)])
        case .rowHeights: nil
        }
        if let values, !values.canSend(in: model) { return false }
        // Every pane of the screen keeps its content's size through the spring and lays it out once at the landing; a
        // trade keeps its left column (and the camera) in place, so only the divider between them moves.
        if case .columnTrade(let left, _, _, _) = change {
            view.keyboardResizeWillChange(screenContaining: pane, keeping: left)
        } else {
            view.keyboardResizeWillChange(screenContaining: pane)
        }
        var sent = true
        if let values {
            sent = values.send(in: model)
        } else if case .rowHeights(let column, let heights) = change {
            model.setRowHeights(column, heights: heights, fit: heights.reduce(0) { $0 + $1.height } == 1000)
        }
        // The spring gets its targets in the key's own turn, so the very next display frame moves (never one that ran
        // before the layout's observation turn), and that frame tick is the press's one layout: the key's turn presents
        // nothing and sizes no content (FRAME OWNER S1B; each terminal's final grid goes in that tick).
        view.syncWithModelForNextFrame()
        view.keyboardResizeDidChange(screenContaining: pane)
        return sent
    }

    /// The column before (`forward == false`) or after the pane's column.
    public static func adjacentColumn(of pane: LayoutPaneID, forward: Bool, in layout: ScreenLayout) -> LayoutColumn? {
        // Visual order: a docked column sits at its edge whatever its daemon index.
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
