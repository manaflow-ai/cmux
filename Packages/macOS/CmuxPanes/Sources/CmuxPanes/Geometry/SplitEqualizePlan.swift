/// The pure outcome of planning an equalize pass over a split tree: the
/// divider moves to apply (children before their parent, preserving the
/// legacy post-order application sequence), whether any split matched the
/// orientation filter, and whether any matched split carried an unparseable
/// id (which the legacy code counted as a failed equalize).
public struct SplitEqualizePlan: Equatable, Sendable {
    /// Divider moves in application order (post-order: children first).
    public let adjustments: [SplitDividerAdjustment]
    /// Whether any split matched the orientation filter.
    public let foundSplit: Bool
    /// Whether a matched split's id failed to parse as a UUID.
    public let hadInvalidSplitIds: Bool

    /// Creates a plan.
    public init(adjustments: [SplitDividerAdjustment], foundSplit: Bool, hadInvalidSplitIds: Bool) {
        self.adjustments = adjustments
        self.foundSplit = foundSplit
        self.hadInvalidSplitIds = hadInvalidSplitIds
    }
}
