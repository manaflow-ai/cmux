public import CmuxNextLayout

/// Keyboard pane resizing and column navigation over one screen's layout.
///
/// One rule for every pane (plans/cmux-next/pane-keys.md; Lawrence 2026-11-07: "ctrl shift hjkl is still unintuitive
/// to me, with regards to splits and columns"): Resize Right / Down (Ctrl-Shift-L / J) make the focused pane one step
/// wider / taller, Resize Left / Up (Ctrl-Shift-H / K) one step narrower / shorter, wherever the pane sits. The edge
/// that moves is the pane's right (bottom) edge; when that edge is the screen's own (the last strip column, the right
/// pane of a split, the last row, a right or bottom dock), its left (top) edge moves instead. Only the two sides of that
/// edge change, and the press back (H after L) moves the same edge back. Edges, nearest first:
/// - A split edge: the deepest split along the arrow's axis with the pane on that side; its ratio moves.
/// - A strip column's edge: the right one when a strip column follows it, else the left one (the last column). The two
///   columns beside it trade width (an Option-drag's trade): the columns after them and the strip's camera stay. One
///   column alone moves its right edge, after any split inside it (it has no neighbor across that edge).
/// - A side dock's inner edge (Left / Right), a top or bottom dock's inner edge (Up / Down), a row edge (rows-v1, Up /
///   Down: the edge below the row, or above it for the last row).
/// Before (#34123, 2026-11-03), a press moved the divider in the arrow's direction, as Ghostty's `resize_split` and
/// tmux do: the same key grew the left pane and shrank the right one. A press steps from the size the screen shows and
/// stops at the size it can show (`shown`): one equal step, the part step that reaches a pane's minimum or the edge of
/// the strip the window shows, or no change at all; never a model change that moves nothing.
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
        // Right and Down grow the pane, Left and Up shrink it.
        let grow = direction == .right || direction == .down ? step : -step
        let tree: SplitNode?
        switch layout {
        case .splits(let root): tree = root
        case .columns: tree = layout.column(containing: pane)?.tree(containing: pane)
        }
        // The far (right / bottom) edge first: a split with the pane before its divider grows the pane as its ratio grows.
        if let tree, let (split, ratio) = edgeSplit(containing: pane, axis: axis, paneFirst: true, in: tree) {
            return stepped(ratio, by: grow, within: SplitRatio.range, shown: shown?.ratio(of: split)).map { .splitRatio(split, $0) }
        }
        let container = containerEdge(of: pane, axis: axis, grow: grow, in: layout, shown: shown)
        if let container, container.isFar { return container.change }
        // The near (left / top) edge: a split with the pane after its divider grows the pane as its ratio shrinks.
        if let tree, let (split, ratio) = edgeSplit(containing: pane, axis: axis, paneFirst: false, in: tree) {
            return stepped(ratio, by: -grow, within: SplitRatio.range, shown: shown?.ratio(of: split)).map { .splitRatio(split, $0) }
        }
        return container?.change
    }

    /// The edge of `pane`'s column, row or dock along `axis` (columns mode): whether it is the pane's far (right / bottom)
    /// edge, and the change that grows the pane by `grow` across it (nil at its limit). Nil when the container has no
    /// edge there (a split screen, a full-height column with no rows, a lone dock).
    private static func containerEdge(of pane: LayoutPaneID, axis: SplitAxis, grow: Double, in layout: ScreenLayout,
                                      shown: ShownResizeRange?) -> (isFar: Bool, change: Change?)? {
        guard let column = layout.column(containing: pane) else { return nil }
        let range = ColumnWidthPreset.widthRange
        // A top or bottom dock's extent is its height; its inner edge is a top dock's bottom and a bottom dock's top.
        if let edge = column.dock?.edge, edge.isBand {
            guard axis == .vertical else { return nil }
            let extent = min(max(column.width + grow, range.lowerBound), range.upperBound)
            return (edge == .top, extent == column.width ? nil : .columnWidth(column.id, extent))
        }
        if axis == .vertical {
            // A row (rows-v1): the edge below it, or above it for the last row.
            guard column.hasRows, let index = column.rows.firstIndex(where: { $0.root.contains(pane) }) else { return nil }
            let isFar = index + 1 < column.rows.count
            return (isFar, shown?.rowHeights(moving: pane, in: column, by: isFar ? grow : -grow).map { .rowHeights(column.id, $0) })
        }
        let parts = DockStripGeometry.docks(layout.columns)
        // A side dock's inner edge, inside the widths it shows: a left dock's right edge, a right dock's left edge.
        if parts.left?.id == column.id || parts.right?.id == column.id {
            let change = stepped(column.width, by: grow, within: range, shown: shown?.dockWidth(of: column)).map { Change.columnWidth(column.id, $0) }
            return (parts.left?.id == column.id, change)
        }
        let strip = parts.scrolling
        guard let index = strip.firstIndex(where: { $0.id == column.id }) else { return nil }
        guard strip.count > 1 else {
            // A screen whose only column is a dock shows it full width whatever its width (`DockStripGeometry.docks`): no
            // press moves it.
            guard strip[index].dock == nil else { return nil }
            // A lone column has no neighbor across its edge: it counts as a near edge, so a split inside it comes first
            // on both sides and the press back always takes the same edge.
            return (false, stepped(column.width, by: grow, within: range, shown: shown?.width(of: column)).map { .columnWidth(column.id, $0) })
        }
        // The divider moves right by `delta` in a trade: right for a column that grows across its right edge, left for the
        // last column, which grows across its left edge.
        let isFar = index + 1 < strip.count
        let (left, right) = isFar ? (strip[index], strip[index + 1]) : (strip[index - 1], strip[index])
        return (isFar, shown?.trade(left, right, by: isFar ? grow : -grow, in: layout).map { .columnTrade(left.id, $0.left, right.id, $0.right) })
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
        // Every pane of the screen is on the key hold through the spring (its content follows it in every frame; a
        // terminal's or a browser's producer hears the hold, `PaneContentAreaView`); a trade keeps its left column (and the camera) in place, so only the divider between them moves.
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

    /// The deepest split along `axis` with `pane` on one side of its divider: in its first child (`paneFirst`, the
    /// divider is the pane's right or bottom edge) or in its second (the divider is its left or top edge).
    static func edgeSplit(containing pane: LayoutPaneID, axis: SplitAxis, paneFirst: Bool, in node: SplitNode) -> (LayoutSplitID, Double)? {
        guard case let .split(id, nodeAxis, ratio, a, b) = node else { return nil }
        let inA = a.contains(pane)
        guard inA || b.contains(pane) else { return nil }
        if let deeper = edgeSplit(containing: pane, axis: axis, paneFirst: paneFirst, in: inA ? a : b) { return deeper }
        return nodeAxis == axis && inA == paneFirst ? (id, ratio) : nil
    }
}
