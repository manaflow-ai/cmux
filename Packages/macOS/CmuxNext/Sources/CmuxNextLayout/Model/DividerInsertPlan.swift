/// Where Insert New at a split's divider puts its pane, in layout ids (the same rule as
/// cmux-layout-reducer `divider_insert::plan`, whose tests cover the shapes). The split is binary,
/// so its divider sits between its `a` and `b` sides: the new pane opens right after `a`'s last
/// pane, wrapping all of `a` when `a` is more than one pane, and the divider moves to two thirds so
/// `a`, the new pane and `b` share the split's old extent evenly (the new split itself is 0.5).
public nonisolated struct DividerInsertPlan: Hashable, Sendable {
    /// The ratio the divider's split takes: `a` and the new pane hold two thirds, `b` the rest.
    public static let dividerRatio = 2.0 / 3.0

    /// The pane the split request names: `a`'s last pane, which touches the divider.
    public var target: PaneID
    /// `a`'s split when `a` is more than one pane (the new pane wraps it whole); nil to split
    /// `target` alone.
    public var around: SplitID?
    /// The divider's axis, which the new split takes.
    public var axis: SplitAxis
    /// The divider's new ratio, shown with the new pane (``LayoutModel/showSplitSizing(_:)``).
    public var sizing: [SplitRatioChange]
}

extension SplitNode {
    /// The insertion at `split`'s divider, or nil when this tree has no such split.
    public func dividerInsertPlan(at split: SplitID) -> DividerInsertPlan? {
        guard let node = node(for: split), let target = node.a.panes.last else { return nil }
        let around: SplitID? = if case let .split(id, _, _, _, _) = node.a { id } else { nil }
        return DividerInsertPlan(target: target, around: around, axis: node.axis,
                                 sizing: [SplitRatioChange(split: split, ratio: DividerInsertPlan.dividerRatio)])
    }

    /// The divider beside `pane` when no divider is named (the palette, a script): the innermost split
    /// with `pane` on its first side (the divider after it), else the innermost split holding it (the
    /// divider before it, for a last pane). Nil when `pane` is not in a split of this tree.
    public func divider(beside pane: PaneID) -> SplitID? {
        guard case let .split(id, _, _, a, b) = self, contains(pane) else { return nil }
        if a.contains(pane) { return a.divider(after: pane) ?? id }
        return b.divider(beside: pane) ?? id
    }

    /// The innermost split with `pane` on its first side.
    private func divider(after pane: PaneID) -> SplitID? {
        guard case let .split(id, _, _, a, b) = self else { return nil }
        if a.contains(pane) { return a.divider(after: pane) ?? id }
        return b.divider(after: pane)
    }
}

extension LayoutModel {
    /// The insertion at `split`'s divider on any screen of the workspace, or nil when no screen
    /// shows that split.
    public func dividerInsertPlan(at split: SplitID) -> DividerInsertPlan? {
        screens.lazy.compactMap { $0.layout.tree(containing: split)?.dividerInsertPlan(at: split) }.first
    }

    /// The divider beside `pane` (``SplitNode/divider(beside:)``), or nil when its tree has no split.
    public func divider(beside pane: PaneID) -> SplitID? {
        guard let layout = screen(containing: pane)?.layout else { return nil }
        let tree: SplitNode? = switch layout {
        case let .splits(root): root
        case .columns: layout.column(containing: pane)?.tree(containing: pane)
        }
        return tree?.divider(beside: pane)
    }

    /// Whether `split`'s divider draws no line (Hide Divider, kept on the split in the daemon's layout).
    public func dividerHidden(_ split: SplitID) -> Bool {
        screens.contains { $0.hiddenDividers.contains(split) }
    }
}
