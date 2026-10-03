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
public nonisolated enum DockDefaults {
    /// A dock's share of the window: the column's width, clamped here.
    public static let widthRange: ClosedRange<Double> = 0.25...0.40

    public static func width(for current: Double) -> Double {
        min(max(current, widthRange.lowerBound), widthRange.upperBound)
    }

    /// Red stub: replaced by the real rule in the next commit.
    public static func edge(for column: ColumnID, in layout: ScreenLayout) -> StickyEdge { .top }

    /// Red stub: replaced by the real rule in the next commit.
    public static func plan(screen: LayoutScreen, column: ColumnID, pane: PaneID?, edge: StickyEdge?,
                            mode: StickyMode) -> DockPlan? { nil }
}
