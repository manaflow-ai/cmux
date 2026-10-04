public import CoreGraphics

/// Why a split cannot happen.
public nonisolated enum SplitRefusal: Hashable, Sendable {
    /// Splitting would push a pane below `LayoutStyle.minimumPaneSize`.
    case notEnoughRoom
}

/// Where a requested split of a pane goes.
public nonisolated enum SplitPlacement: Hashable, Sendable {
    /// The pane splits in place and every pane keeps its minimum size.
    case split
    /// Columns screen, side-by-side split, and the pane's column has no room
    /// for two panes across: open a new column after it instead. Horizontal
    /// space in a column strip is unbounded, so the column strip grows rather
    /// than squeezing panes.
    case newColumn
    /// The split cannot fit. Stacked splits in a column and every split on a
    /// plain split screen have a fixed container, so they refuse.
    case refused(SplitRefusal)
}

/// Decides whether a split fits before it is sent to the daemon. Pure: the
/// caller passes the screen's layout, its viewport and the style.
public nonisolated enum SplitRoom {
    /// Placement for splitting `pane` along `axis` on a screen with `layout`
    /// shown in `viewport`. `removing` is a pane that leaves in the same step
    /// (the source of a moved tab that was its only tab). An unknown pane or
    /// an unmeasured viewport returns `.split`: the daemon decides.
    public static func placement(
        splitting pane: PaneID,
        axis: SplitAxis,
        in layout: ScreenLayout,
        viewport: CGSize,
        style: LayoutStyle,
        removing: PaneID? = nil
    ) -> SplitPlacement {
        guard viewport.width > 0, viewport.height > 0 else { return .split }
        let removing = removing == pane ? nil : removing
        switch layout {
        case let .splits(root):
            guard root.contains(pane) else { return .split }
            let need = minimumSize(splitting: pane, axis: axis, in: root, removing: removing, style: style)
            return fits(need, in: viewport) ? .split : .refused(.notEnoughRoom)
        case let .columns(columns):
            guard let index = columns.firstIndex(where: { $0.root.contains(pane) }) else { return .split }
            // The column's real frame: a sticky column is capped, docked
            // strip columns are shares of the strip (sticky-column.md S3, S4).
            let geometry = ScreenGeometry.compute(layout, viewport: viewport, style: style, scale: 2)
            // A band or a strip that a band shortened is not the viewport's height.
            // In a column of rows the split stays inside the pane's row.
            let row = columns[index].hasRows ? columns[index].row(containing: pane) : nil
            let frame = row.flatMap { geometry.rowStacks[columns[index].id]?.frame(of: $0.id) } ?? geometry.columns[columns[index].id]
            let container = CGSize(width: frame?.width ?? viewport.width, height: frame?.height ?? viewport.height)
            let need = minimumSize(splitting: pane, axis: axis, in: row?.root ?? columns[index].root, removing: removing, style: style)
            if fits(need, in: container) { return .split }
            // A sticky column never grows a neighbor column.
            if geometry.fixedPanes.contains(pane) { return .refused(.notEnoughRoom) }
            if axis == .horizontal, fits(style.minimumPaneSize, in: CGSize(width: max(1, viewport.width - style.stripGap * 2), height: viewport.height)) {
                return .newColumn
            }
            return .refused(.notEnoughRoom)
        }
    }

    /// Minimum size of `tree` after `removing` leaves and `pane` splits.
    static func minimumSize(splitting pane: PaneID, axis: SplitAxis, in tree: SplitNode, removing: PaneID?, style: LayoutStyle) -> CGSize {
        let pruned = removing.flatMap { tree.removing($0) } ?? tree
        let split = pruned.replacingLeaf(pane) { .split("room-check", axis: axis, ratio: 0.5, a: $0, b: .leaf("room-check")) }
        return SplitGeometry.minimumSize(of: split, style: style)
    }

    static func fits(_ size: CGSize, in container: CGSize) -> Bool {
        size.width <= container.width + 0.5 && size.height <= container.height + 0.5
    }
}
