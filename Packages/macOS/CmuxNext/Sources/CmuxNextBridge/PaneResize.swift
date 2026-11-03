public import CmuxNextLayout

/// Keyboard pane resizing and column navigation over one screen's layout.
/// Resizing moves the divider nearest the pane in the arrow's direction;
/// in columns mode a left or right
/// resize with no horizontal split in the column changes the column width.
/// A press steps from the size the screen shows and stops at the size it can show (`shown`): one equal step, the
/// part step that reaches a pane's minimum, or no change at all; never a model change that moves nothing.
public nonisolated enum PaneResize {
    public enum Change: Equatable, Sendable {
        case splitRatio(LayoutSplitID, Double)
        case columnWidth(LayoutColumnID, Double)
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
        return stepped(column.width, by: delta, within: range, shown: shown?.width(of: column)).map { .columnWidth(column.id, $0) }
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
        let change = change(for: pane, direction: direction, in: screen.layout, shown: view.shownResizeRange(ofScreenContaining: pane))
        // Every pane of the screen keeps its content's size through the spring and lays it out once at the landing.
        if change != nil { view.keyboardResizeWillChange(screenContaining: pane) }
        switch change {
        case .splitRatio(let split, let ratio): model.setSplitRatio(split, ratio: ratio, transaction: .make(), phase: .ended)
        case .columnWidth(let column, let width): model.setColumnWidth(column, width: width, transaction: .make(), phase: .ended)
        case .rowHeights(let column, let heights): model.setRowHeights(column, heights: heights, fit: heights.reduce(0) { $0 + $1.height } == 1000)
        case nil: return false
        }
        // The spring gets its targets in the key's own turn, so the very next display frame moves (never one that ran
        // before the layout's observation turn), and that frame tick is the press's one layout: the key's turn presents
        // nothing and sizes no content (FRAME OWNER S1B; each terminal's final grid goes in that tick).
        view.syncWithModelForNextFrame()
        return true
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
