public import CoreGraphics

/// Ratios that give every pane along a split axis an equal share after a
/// split (`layout.splitSizing` = even, plans/cmux-next/column-sizing.md).
public nonisolated enum EvenSplitRatios {
    /// The ratio changes for splitting `pane` along `axis` in `root`: every
    /// split of the same-axis chain that will hold the new split, set so
    /// each cell of that chain (the split pane counting as two) gets an
    /// equal share. The new split itself is 0.5 already. Unchanged splits
    /// are left out.
    public static func changes(splitting pane: PaneID, axis: SplitAxis, in root: SplitNode) -> [SplitRatioChange] {
        guard let top = chainTop(of: pane, axis: axis, in: root) else { return [] }
        var result: [SplitRatioChange] = []
        collect(top, pane: pane, axis: axis, into: &result)
        return result
    }

    /// The ratio changes that give every cell of the same-axis chain under `top` an equal share
    /// (a close, `pane_close_split_changes`). Unchanged splits are left out.
    public static func changes(equalizing top: SplitNode, axis: SplitAxis) -> [SplitRatioChange] {
        var result: [SplitRatioChange] = []
        equalize(top, axis: axis, into: &result)
        return result
    }

    /// The ratio changes that give every cell of the same-axis chain holding `split` an equal share: the chain's top is
    /// the highest ancestor reached through splits of `split`'s axis alone, so the panes on both sides of the divider and
    /// their same-axis neighbours (above it and below it in the tree) all end even (a divider's double-click, #57175).
    /// Perpendicular subtrees count as one cell and keep their own ratios. Unchanged splits are left out; empty when
    /// `split` is not in `root`.
    public static func changes(equalizingChainOf split: SplitID, in root: SplitNode) -> [SplitRatioChange] {
        guard let top = chainTop(of: split, in: root), case let .split(_, axis, _, _, _) = top else { return [] }
        return changes(equalizing: top, axis: axis)
    }

    /// The highest split of the same-axis chain holding `split`: the highest ancestor reached through splits of
    /// `split`'s axis alone (`split` itself when its parent splits across). Nil when `split` is not in `root`.
    public static func chainTop(of split: SplitID, in root: SplitNode) -> SplitNode? {
        var path: [SplitNode] = []
        guard splitPath(to: split, in: root, path: &path), case let .split(_, axis, _, _, _)? = path.last else { return nil }
        var top = path.removeLast()
        while case let .split(_, parentAxis, _, _, _)? = path.last, parentAxis == axis { top = path.removeLast() }
        return top
    }

    /// The ratio changes that give every cell of the same-axis chain under `top` an equal extent on screen, `extent`
    /// points along `top`'s axis (the container `SplitGeometry` lays `top` out in). Leaf counts alone (the overload
    /// above) are even only while every cell fits its even share: a cell whose panes need more (a perpendicular
    /// stack holding a row of panes, `SplitGeometry.minimumSize`) is clamped to its minimum by the layout and its
    /// sibling alone gave up the difference, so the other cells ended uneven (#57175). Here a cell that needs more
    /// than an even share keeps its minimum and every other cell shares the rest equally; the dividers inside the
    /// chain are counted too. Falls back to leaf counts when the panes cannot all fit (the layout then shares by
    /// minimums). A change that moves no divider by a quarter point or more is left out.
    public static func changes(equalizing top: SplitNode, extent: CGFloat, style: LayoutStyle) -> [SplitRatioChange] {
        guard case let .split(_, axis, _, _, _) = top else { return [] }
        let cells = chainCells(top, axis: axis)
        let divider = style.dividerThickness
        let content = extent - divider * CGFloat(cells.count - 1)
        let minimums = cells.map { SplitGeometry.minimumSize(of: $0, style: style).extent(along: axis) }
        guard content > 0, minimums.reduce(0, +) <= content + 0.5 else { return changes(equalizing: top, axis: axis) }
        var sizes = evenShares(of: content, minimums: minimums)[...]
        var result: [SplitRatioChange] = []
        _ = place(top, axis: axis, divider: divider, sizes: &sizes, into: &result)
        return result
    }

    /// `total` shared as evenly as `minimums` allow: a share under a minimum is raised to it and the others share what
    /// is left equally (water filling). The minimums must fit in `total`.
    static func evenShares(of total: CGFloat, minimums: [CGFloat]) -> [CGFloat] {
        var held = Array(repeating: false, count: minimums.count)
        while true {
            let free = minimums.indices.filter { !held[$0] }
            guard !free.isEmpty else { return minimums }
            let share = (total - minimums.indices.filter { held[$0] }.reduce(0) { $0 + minimums[$1] }) / CGFloat(free.count)
            let raised = free.filter { minimums[$0] > share }
            if raised.isEmpty { return minimums.indices.map { held[$0] ? minimums[$0] : share } }
            for index in raised { held[index] = true }
        }
    }

    /// The cells of the same-axis chain under `node`, leading first: its leaves and perpendicular subtrees.
    private static func chainCells(_ node: SplitNode, axis: SplitAxis) -> [SplitNode] {
        guard case let .split(_, nodeAxis, _, a, b) = node, nodeAxis == axis else { return [node] }
        return chainCells(a, axis: axis) + chainCells(b, axis: axis)
    }

    /// Lays the chain under `node` out from its cells' `sizes` (taken leading first) and returns its extent: each
    /// split's ratio is its leading side's extent over both sides' (`SplitGeometry` gives `ratio` of the extent less
    /// the divider to side a).
    private static func place(_ node: SplitNode, axis: SplitAxis, divider: CGFloat, sizes: inout ArraySlice<CGFloat>,
                              into result: inout [SplitRatioChange]) -> CGFloat {
        guard case let .split(id, nodeAxis, ratio, a, b) = node, nodeAxis == axis else { return sizes.popFirst() ?? 0 }
        let first = place(a, axis: axis, divider: divider, sizes: &sizes, into: &result)
        let second = place(b, axis: axis, divider: divider, sizes: &sizes, into: &result)
        let available = first + second
        guard available > 0 else { return divider }
        let even = Double(first / available)
        if abs(even - ratio) * Double(available) >= 0.25 { result.append(SplitRatioChange(split: id, ratio: even)) }
        return available + divider
    }

    /// Fills `path` with the split nodes from `node` down to `split` itself.
    private static func splitPath(to split: SplitID, in node: SplitNode, path: inout [SplitNode]) -> Bool {
        guard case let .split(id, _, _, a, b) = node else { return false }
        path.append(node)
        if id == split || splitPath(to: split, in: a, path: &path) || splitPath(to: split, in: b, path: &path) { return true }
        path.removeLast()
        return false
    }

    private static func equalize(_ node: SplitNode, axis: SplitAxis, into result: inout [SplitRatioChange]) {
        guard case let .split(id, nodeAxis, ratio, a, b) = node, nodeAxis == axis else { return }
        let wa = Double(a.cellCount(along: axis)), wb = Double(b.cellCount(along: axis))
        let even = wa / (wa + wb)
        if abs(even - ratio) > 1e-6 { result.append(SplitRatioChange(split: id, ratio: even)) }
        equalize(a, axis: axis, into: &result)
        equalize(b, axis: axis, into: &result)
    }

    /// The highest node of the same-axis chain directly above `pane`; nil
    /// when the pane's parent splits across the other axis (or it is the root).
    private static func chainTop(of pane: PaneID, axis: SplitAxis, in root: SplitNode) -> SplitNode? {
        var path: [SplitNode] = []
        guard ancestors(of: pane, in: root, path: &path) else { return nil }
        var top: SplitNode?
        for node in path.reversed() {
            guard case let .split(_, nodeAxis, _, _, _) = node, nodeAxis == axis else { break }
            top = node
        }
        return top
    }

    /// Fills `path` with the split nodes from `node` down to `pane`'s parent.
    private static func ancestors(of pane: PaneID, in node: SplitNode, path: inout [SplitNode]) -> Bool {
        guard case let .split(_, _, _, a, b) = node else { return false }
        path.append(node)
        if a == .leaf(pane) || b == .leaf(pane) { return true }
        if ancestors(of: pane, in: a, path: &path) || ancestors(of: pane, in: b, path: &path) { return true }
        path.removeLast()
        return false
    }

    /// Cells along `axis`, the split pane counting as two.
    private static func weight(_ node: SplitNode, pane: PaneID, axis: SplitAxis) -> Double {
        Double(node.cellCount(along: axis) + (node.contains(pane) ? 1 : 0))
    }

    private static func collect(_ node: SplitNode, pane: PaneID, axis: SplitAxis, into result: inout [SplitRatioChange]) {
        guard case let .split(id, nodeAxis, ratio, a, b) = node, nodeAxis == axis else { return }
        let wa = weight(a, pane: pane, axis: axis), wb = weight(b, pane: pane, axis: axis)
        let even = wa / (wa + wb)
        if abs(even - ratio) > 1e-6 { result.append(SplitRatioChange(split: id, ratio: even)) }
        collect(a, pane: pane, axis: axis, into: &result)
        collect(b, pane: pane, axis: axis, into: &result)
    }
}

/// One split's new ratio.
public nonisolated struct SplitRatioChange: Hashable, Sendable, Decodable {
    public var split: SplitID
    public var ratio: Double

    public init(split: SplitID, ratio: Double) {
        self.split = split
        self.ratio = ratio
    }
}
