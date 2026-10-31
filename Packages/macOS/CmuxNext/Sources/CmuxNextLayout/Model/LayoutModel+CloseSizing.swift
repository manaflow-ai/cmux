public import CmuxNextDesign

/// Sizing on close (Lawrence 2026-10-16, "panes should always equalize when we create and close
/// them"): with `layout.splitSizing` even, a closed pane's same-axis chain shares its space
/// equally again, as a split's chain does (`splitSizingChanges`). With `layout.newColumnWidth`
/// fitScreen, the scrolling columns that fit the viewport share it equally after a column closes.
/// Interim like the split side: ratio and width intents after the daemon's tree, until the layout
/// reducer has a sizing policy.
extension LayoutModel {
    /// Sends the sizing intents for the panes and columns that left between two daemon trees.
    /// `landed`: panes whose close this window showed (`showPaneClose`); their sizes are the landed
    /// close sizes (`noteLandedCloses`), sent once no close is pending on the screen.
    func applyCloseSizing(from old: [LayoutScreen], to new: [LayoutScreen], landed: Set<PaneID> = []) {
        for screen in new {
            guard let before = old.first(where: { $0.id == screen.id }), !before.zoomed, !screen.zoomed else { continue }
            let removed = Set(before.layout.panes).subtracting(screen.layout.panes)
            guard !removed.isEmpty else { continue }
            if splitSizing == .even {
                applySplitSizing(removed.subtracting(landed).flatMap { CloseSizing(old: before.layout, new: screen.layout).splitChanges(closing: $0) })
            }
            // A shown close's widths were noted before the overlay (`noteLandedCloses`).
            if newColumnWidthMode == .fitScreen, removed.isDisjoint(with: landed) {
                for resize in CloseSizing(old: before.layout, new: screen.layout).columnResizes() {
                    setColumnWidth(resize.column, width: resize.width, transaction: .make(), phase: .ended)
                }
            }
        }
    }
}

/// The even sizes a close leaves: the closed pane's sibling takes its parent's place, and the
/// same-axis chain around that place is equalized (each nested group counts as one cell per pane
/// along the axis, `SplitNode.cellCount`).
nonisolated struct CloseSizing {
    let old: ScreenLayout
    let new: ScreenLayout

    func splitChanges(closing pane: PaneID) -> [SplitRatioChange] {
        guard let oldTree = tree(in: old, holding: pane), let (axis, sibling) = Self.parent(of: pane, in: oldTree),
              let neighbor = sibling.panes.first, let newTree = tree(in: new, holding: neighbor) else { return [] }
        let kept = Set(sibling.panes)
        var path: [SplitNode] = []
        guard let place = Self.node(in: newTree, panes: kept, path: &path) else { return [] }
        // The highest node of the same-axis run directly above the sibling's place, else the place itself.
        var top: SplitNode? = Self.splitAxis(place) == axis ? place : nil
        for node in path.reversed() {
            guard Self.splitAxis(node) == axis else { break }
            top = node
        }
        return top.map { EvenSplitRatios.changes(equalizing: $0, axis: axis) } ?? []
    }

    /// Scrolling columns share the viewport equally after a scrolling column closed, while they fit it.
    func columnResizes() -> [ColumnResize] {
        let before = old.columns.filter { $0.dock == nil }, after = new.columns.filter { $0.dock == nil }
        guard after.count < before.count, !after.isEmpty,
              before.reduce(0, { $0 + $1.width }) <= 1.001 else { return [] }
        let range = ColumnWidthPreset.widthRange
        let share = min(max(1.0 / Double(after.count), range.lowerBound), range.upperBound)
        return after.compactMap { abs($0.width - share) > 0.001 ? ColumnResize(column: $0.id, width: share) : nil }
    }

    /// The split tree `pane` lives in (a column's own tree; a column with rows sizes its rows elsewhere).
    private func tree(in layout: ScreenLayout, holding pane: PaneID) -> SplitNode? {
        switch layout {
        case let .splits(root): root.contains(pane) ? root : nil
        case .columns: layout.column(containing: pane).flatMap { $0.hasRows ? nil : $0.root }
        }
    }

    private static func splitAxis(_ node: SplitNode) -> SplitAxis? {
        if case let .split(_, axis, _, _, _) = node { return axis }
        return nil
    }

    /// The axis of `pane`'s parent split and the sibling subtree that takes its place.
    static func parent(of pane: PaneID, in node: SplitNode) -> (SplitAxis, SplitNode)? {
        guard case let .split(_, axis, _, a, b) = node else { return nil }
        if a == .leaf(pane) { return (axis, b) }
        if b == .leaf(pane) { return (axis, a) }
        return parent(of: pane, in: a) ?? parent(of: pane, in: b)
    }

    /// The node holding exactly `panes`, with the splits above it in `path` (root first).
    private static func node(in node: SplitNode, panes: Set<PaneID>, path: inout [SplitNode]) -> SplitNode? {
        if Set(node.panes) == panes { return node }
        guard case let .split(_, _, _, a, b) = node else { return nil }
        path.append(node)
        if let found = Self.node(in: a, panes: panes, path: &path) ?? Self.node(in: b, panes: panes, path: &path) { return found }
        path.removeLast()
        return nil
    }
}
