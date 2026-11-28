/// Ratios that give every pane along a split axis an equal share after a
/// split (`layout.splitSizing` = even, plans/cmux-next/column-sizing.md).
public nonisolated enum EvenSplitRatios {
    /// The ratio changes for splitting `pane` along `axis` in `root`: every
    /// split of the same-axis chain that will hold the new split, set so
    /// each cell of that chain (the split pane counting as two) gets an
    /// equal share. The new split itself is 0.5 already. Unchanged splits
    /// are left out.
    /// Run by cmux-layout-reducer (`layout_model_even_split`; `schemas/layout-model/vectors.json`).
    public static func changes(splitting pane: PaneID, axis: SplitAxis, in root: SplitNode) -> [SplitRatioChange] {
        struct Request: Encodable { var root: SplitNode, pane: PaneID, axis: SplitAxis }
        let reply: Reply? = LayoutRules.call("layout_model_even_split", Request(root: root, pane: pane, axis: axis))
        return reply?.changes ?? []
    }

    struct Reply: Decodable { var changes: [SplitRatioChange] }

    /// The ratio changes that give every cell of the same-axis chain under `top` an equal share
    /// (a close, `pane_close_split_changes`). Unchanged splits are left out.
    public static func changes(equalizing top: SplitNode, axis: SplitAxis) -> [SplitRatioChange] {
        var result: [SplitRatioChange] = []
        equalize(top, axis: axis, into: &result)
        return result
    }

    private static func equalize(_ node: SplitNode, axis: SplitAxis, into result: inout [SplitRatioChange]) {
        guard case let .split(id, nodeAxis, ratio, a, b) = node, nodeAxis == axis else { return }
        let wa = Double(a.cellCount(along: axis)), wb = Double(b.cellCount(along: axis))
        let even = wa / (wa + wb)
        if abs(even - ratio) > 1e-6 { result.append(SplitRatioChange(split: id, ratio: even)) }
        equalize(a, axis: axis, into: &result)
        equalize(b, axis: axis, into: &result)
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
