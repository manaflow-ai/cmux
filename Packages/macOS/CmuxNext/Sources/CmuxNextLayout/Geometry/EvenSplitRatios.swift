/// Ratios that give every pane along a split axis an equal share after a
/// split (`layout.splitSizing` = even, plans/cmux-next/column-sizing.md).
public nonisolated enum EvenSplitRatios {
    /// The ratio changes for splitting `pane` along `axis` in `root`: every
    /// split of the same-axis chain that will hold the new split, set so
    /// each cell of that chain (the split pane counting as two) gets an
    /// equal share. The new split itself is 0.5 already. Unchanged splits
    /// are left out.
    public static func changes(splitting pane: PaneID, axis: SplitAxis, in root: SplitNode) -> [SplitRatioChange] {
        []
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
