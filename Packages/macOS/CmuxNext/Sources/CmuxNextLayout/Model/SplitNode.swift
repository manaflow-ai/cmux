/// Orientation of a split.
public nonisolated enum SplitAxis: String, Hashable, Sendable {
    /// Children side by side; `a` is on the left. Daemon `dir: "right"`.
    case horizontal
    /// Children stacked; `a` is on top. Daemon `dir: "down"`.
    case vertical
}

/// A binary split tree whose leaves are panes.
public nonisolated indirect enum SplitNode: Hashable, Sendable {
    case leaf(PaneID)
    /// `ratio` is the fraction of the space (minus the divider) given to `a`.
    case split(SplitID, axis: SplitAxis, ratio: Double, a: SplitNode, b: SplitNode)

    /// Leaves in visual order (left to right, top to bottom).
    public var panes: [PaneID] {
        var result: [PaneID] = []
        collectPanes(into: &result)
        return result
    }

    private func collectPanes(into result: inout [PaneID]) {
        switch self {
        case let .leaf(pane): result.append(pane)
        case let .split(_, _, _, a, b):
            a.collectPanes(into: &result)
            b.collectPanes(into: &result)
        }
    }

    /// Every split id in the tree, depth first.
    public var splits: [SplitID] {
        switch self {
        case .leaf: []
        case let .split(id, _, _, a, b): [id] + a.splits + b.splits
        }
    }

    /// Same leaves, splits and axes in the same places; ratios may differ.
    public func hasSameShape(as other: SplitNode) -> Bool {
        switch (self, other) {
        case let (.leaf(x), .leaf(y)):
            return x == y
        case let (.split(xID, xAxis, _, xa, xb), .split(yID, yAxis, _, ya, yb)):
            return xID == yID && xAxis == yAxis && xa.hasSameShape(as: ya) && xb.hasSameShape(as: yb)
        default:
            return false
        }
    }

    public func contains(_ pane: PaneID) -> Bool {
        switch self {
        case let .leaf(leaf): leaf == pane
        case let .split(_, _, _, a, b): a.contains(pane) || b.contains(pane)
        }
    }

    /// The ratio of `split`, if it exists in this tree.
    public func ratio(of split: SplitID) -> Double? {
        switch self {
        case .leaf: return nil
        case let .split(id, _, ratio, a, b):
            if id == split { return ratio }
            return a.ratio(of: split) ?? b.ratio(of: split)
        }
    }

    /// Axis and children of `split`, if it exists in this tree.
    public func node(for split: SplitID) -> (axis: SplitAxis, a: SplitNode, b: SplitNode)? {
        switch self {
        case .leaf: return nil
        case let .split(id, axis, _, a, b):
            if id == split { return (axis, a, b) }
            return a.node(for: split) ?? b.node(for: split)
        }
    }

    /// A copy with `split`'s ratio replaced. Unchanged if the split is absent.
    public func settingRatio(_ ratio: Double, for split: SplitID) -> SplitNode {
        switch self {
        case .leaf: return self
        case let .split(id, axis, old, a, b):
            if id == split { return .split(id, axis: axis, ratio: ratio, a: a, b: b) }
            return .split(id, axis: axis, ratio: old, a: a.settingRatio(ratio, for: split), b: b.settingRatio(ratio, for: split))
        }
    }

    /// Number of equal cells this subtree contributes along `axis`. A chain of
    /// same-axis splits counts its leaves; a perpendicular subtree counts as one.
    public func cellCount(along axis: SplitAxis) -> Int {
        switch self {
        case .leaf: return 1
        case let .split(_, nodeAxis, _, a, b):
            return nodeAxis == axis ? a.cellCount(along: axis) + b.cellCount(along: axis) : 1
        }
    }

    /// The ratio for `split` that gives every cell in its same-axis chain equal size.
    public func equalizedRatio(for split: SplitID) -> Double? {
        guard let node = node(for: split) else { return nil }
        let a = Double(node.a.cellCount(along: node.axis))
        let b = Double(node.b.cellCount(along: node.axis))
        return a / (a + b)
    }

    /// A copy with the leaf `pane` replaced by `transform(leaf)`.
    public func replacingLeaf(_ pane: PaneID, with transform: (SplitNode) -> SplitNode) -> SplitNode {
        switch self {
        case let .leaf(leaf):
            return leaf == pane ? transform(self) : self
        case let .split(id, axis, ratio, a, b):
            return .split(id, axis: axis, ratio: ratio, a: a.replacingLeaf(pane, with: transform), b: b.replacingLeaf(pane, with: transform))
        }
    }

    /// A copy without the leaf `pane`; its sibling takes the parent's place.
    /// Nil when `pane` was the only leaf. Unchanged when `pane` is absent.
    public func removing(_ pane: PaneID) -> SplitNode? {
        switch self {
        case let .leaf(leaf):
            return leaf == pane ? nil : self
        case let .split(id, axis, ratio, a, b):
            guard let first = a.removing(pane) else { return b }
            guard let second = b.removing(pane) else { return a }
            return .split(id, axis: axis, ratio: ratio, a: first, b: second)
        }
    }
}
