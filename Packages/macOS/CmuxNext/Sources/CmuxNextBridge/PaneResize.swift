public import CmuxNextLayout

/// Keyboard pane resizing and column navigation over one screen's layout.
///
/// Two rules (plans/cmux-next/pane-keys.md):
/// - A split, inside a screen or a column, and a rows-v1 row edge: the divider moves in the arrow's direction, as tmux,
///   Ghostty's `resize_split` and the divider a person sees suggest (Lawrence 2026-11-11: "ctrl shift hl behavior is
///   unintuitive when i'm in a column, i think it sizes things the wrong way"). The nearest split along the arrow's axis
///   around the focused pane takes the press, on whichever side of it the pane is; H / L never move a stacked split and
///   K / J never a side-by-side one. A divider at its limit refuses the press: no other edge moves instead.
/// - A strip column or a dock with no such split around the pane: Resize Right / Down (Ctrl-Shift-L / J) make it one step
///   wider / taller and Left / Up narrower / shorter (niri's column width +/-; Lawrence 2026-11-07: "ctrl shift hjkl is
///   still unintuitive to me, with regards to splits and columns"). A strip column trades width with the next column
///   across its right edge, or the previous one across its left edge for the last column; the columns after them and
///   the strip's camera stay. One column alone gets wider or narrower on its own; a dock moves its inner edge.
/// Between 2026-11-08 and 2026-11-11 splits grew or shrank the focused pane too, so H on the right pane of a split moved
/// the divider right. A press steps from the size the screen shows and stops at the size it can show (`shown`): one
/// equal step, the part step that reaches a pane's minimum or the edge of the strip the window shows, or no change at
/// all; never a model change that moves nothing.
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
        // A divider follows the arrow: Right and Down move it right / down.
        let arrow = direction == .right || direction == .down ? step : -step
        let tree: SplitNode?
        switch layout {
        case .splits(let root): tree = root
        case .columns: tree = layout.column(containing: pane)?.tree(containing: pane)
        }
        // The nearest split along the arrow's axis around the pane: its divider moves in the arrow's direction, whichever
        // side the pane is on. At its limit the press is refused: no other edge moves instead.
        if let tree, let (split, ratio) = nearestSplit(containing: pane, axis: axis, in: tree) {
            return stepped(ratio, by: arrow, within: SplitRatio.range, shown: shown?.ratio(of: split)).map { .splitRatio(split, $0) }
        }
        // Rows (rows-v1) read as stacked splits: the row edge follows the arrow too.
        if axis == .vertical, let column = layout.column(containing: pane), column.hasRows, column.dock?.edge.isBand != true {
            return shown?.rowHeights(moving: pane, in: column, by: arrow).map { .rowHeights(column.id, $0) }
        }
        // A strip column or a dock with no split along the axis: Right / Down grow it, Left / Up shrink it.
        let grow = direction == .right || direction == .down ? step : -step
        return containerEdge(of: pane, axis: axis, grow: grow, in: layout, shown: shown)
    }

    /// The change that grows `pane`'s strip column or dock by `grow` along `axis` (columns mode): across its right edge,
    /// or its left edge for the last strip column, or a dock's inner edge. Nil at its limit, or when the container has no
    /// edge there (a split screen, a full-height column, a lone dock).
    private static func containerEdge(of pane: LayoutPaneID, axis: SplitAxis, grow: Double, in layout: ScreenLayout,
                                      shown: ShownResizeRange?) -> Change? {
        guard let column = layout.column(containing: pane) else { return nil }
        let range = ColumnWidthPreset.widthRange
        // A top or bottom dock's extent is its height; its inner edge is a top dock's bottom and a bottom dock's top.
        if let edge = column.dock?.edge, edge.isBand {
            guard axis == .vertical else { return nil }
            let extent = min(max(column.width + grow, range.lowerBound), range.upperBound)
            return extent == column.width ? nil : .columnWidth(column.id, extent)
        }
        guard axis == .horizontal else { return nil }
        let parts = DockStripGeometry.docks(layout.columns)
        // A side dock's inner edge, inside the widths it shows: a left dock's right edge, a right dock's left edge.
        if parts.left?.id == column.id || parts.right?.id == column.id {
            return stepped(column.width, by: grow, within: range, shown: shown?.dockWidth(of: column)).map { .columnWidth(column.id, $0) }
        }
        let strip = parts.scrolling
        guard let index = strip.firstIndex(where: { $0.id == column.id }) else { return nil }
        guard strip.count > 1 else {
            // A screen whose only column is a dock shows it full width whatever its width (`DockStripGeometry.docks`): no
            // press moves it.
            guard strip[index].dock == nil else { return nil }
            // A lone column has no neighbor across its edge: it gets wider or narrower on its own.
            return stepped(column.width, by: grow, within: range, shown: shown?.width(of: column)).map { .columnWidth(column.id, $0) }
        }
        // The divider moves right by `delta` in a trade: right for a column that grows across its right edge, left for the
        // last column, which grows across its left edge.
        let isFar = index + 1 < strip.count
        let (left, right) = isFar ? (strip[index], strip[index + 1]) : (strip[index - 1], strip[index])
        return shown?.trade(left, right, by: isFar ? grow : -grow, in: layout).map { .columnTrade(left.id, $0.left, right.id, $0.right) }
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

    /// The deepest split along `axis` with `pane` on either side of its divider.
    static func nearestSplit(containing pane: LayoutPaneID, axis: SplitAxis, in node: SplitNode) -> (LayoutSplitID, Double)? {
        guard case let .split(id, nodeAxis, ratio, a, b) = node else { return nil }
        let inA = a.contains(pane)
        guard inA || b.contains(pane) else { return nil }
        if let deeper = nearestSplit(containing: pane, axis: axis, in: inA ? a : b) { return deeper }
        return nodeAxis == axis ? (id, ratio) : nil
    }
}
