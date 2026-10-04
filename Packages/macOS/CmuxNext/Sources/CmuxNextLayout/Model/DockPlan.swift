/// "Dock Column" (plans/cmux-next/layout-model.md): what one dock request
/// does, decided from the layout alone so every entry point (palette, CLI,
/// context menu, MCP) behaves the same. The daemon still owns the result.
public nonisolated enum DockPlan: Hashable, Sendable {
    /// Pin the column at the edge and size it to `width`, in one transaction.
    case pin(ColumnID, StickyColumn, width: Double)
    /// The column scrolls again.
    case undock(ColumnID)
    /// The column is the screen's only scrolling column, so it must keep
    /// scrolling: the pane's active tab moves into a new column pinned at the
    /// edge (move-tab-to-column with `sticky`).
    case moveTab(PaneID, StickyColumn, width: Double)
}

/// The defaults a dock request uses when it names no edge or width.
public struct DockDefaults {
    public nonisolated init() {}
    /// A dock's share of the window: the column's width, clamped here.
    public nonisolated let widthRange: ClosedRange<Double> = 0.25...0.40

    public nonisolated func width(for current: Double) -> Double {
        min(max(current, widthRange.lowerBound), widthRange.upperBound)
    }

    /// The edge a column docks to by default: left for the leftmost of
    /// several scrolling columns, else right. A side another column holds
    /// yields to the free side, so docking never silently undocks another.
    public nonisolated func edge(for column: ColumnID, in layout: ScreenLayout) -> StickyEdge {
        let scrolling = layout.columns.filter { $0.sticky == nil }
        let near: StickyEdge = scrolling.count > 1 && scrolling.first?.id == column ? .left : .right
        let held = { (edge: StickyEdge) in layout.columns.contains { $0.id != column && $0.sticky?.edge == edge } }
        let far: StickyEdge = near == .left ? .right : .left
        return held(near) && !held(far) ? far : near
    }

    /// What docking `column` does. `edge` nil uses the column's own edge
    /// when it has one, else `defaultEdge` (cmux.json
    /// `layout.stickyColumnEdge` when set), else `edge(for:in:)`. Asking for the state the
    /// column already has (same mode, no other edge) undocks it, so running
    /// the action again is the undo. `pane` is the pane whose tab moves when
    /// the column must keep scrolling (default: the column's first pane).
    /// Nil only when the screen has no such column.
    public nonisolated func plan(screen: LayoutScreen, column id: ColumnID, pane: PaneID?, edge: StickyEdge?,
                            defaultEdge: StickyEdge? = nil, mode: StickyMode) -> DockPlan? {
        guard let column = screen.column(id: id) else { return nil }
        if let current = column.sticky, current.mode == mode, edge == nil || edge == current.edge {
            return .undock(id)
        }
        let chosen = edge ?? column.sticky?.edge ?? defaultEdge ?? self.edge(for: id, in: screen.layout)
        let target = StickyColumn(edge: chosen, mode: mode)
        let width = self.width(for: column.width)
        // The implicit column, or the last scrolling one, must keep scrolling.
        let othersScroll = screen.layout.columns.contains { $0.id != id && $0.sticky == nil }
        if id == screen.implicitColumnID || (column.sticky == nil && !othersScroll) {
            guard let anchor = pane.flatMap({ column.root.contains($0) ? $0 : nil }) ?? column.root.panes.first else { return nil }
            return .moveTab(anchor, target, width: width)
        }
        return .pin(id, target, width: width)
    }
}
