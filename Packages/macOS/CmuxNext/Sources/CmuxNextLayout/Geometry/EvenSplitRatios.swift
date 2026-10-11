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
public nonisolated struct SplitRatioChange: Hashable, Sendable {
    public var split: SplitID
    public var ratio: Double

    public init(split: SplitID, ratio: Double) {
        self.split = split
        self.ratio = ratio
    }
}
