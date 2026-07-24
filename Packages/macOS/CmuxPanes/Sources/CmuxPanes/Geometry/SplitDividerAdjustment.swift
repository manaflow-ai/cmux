public import CoreGraphics
public import Foundation

/// One planned divider move: the split to adjust and the normalized
/// (0.0-1.0) divider position to set on it.
public struct SplitDividerAdjustment: Equatable, Sendable {
    /// The split whose divider moves.
    public let splitId: UUID
    /// The normalized divider position to set.
    public let position: CGFloat
    /// The unclamped share requested for the branch containing the focused pane.
    public let requestedFocusedBranchShare: CGFloat?
    /// The share actually assigned to the branch containing the focused pane.
    public let focusedBranchShare: CGFloat?
    /// The focused branch's share before this adjustment.
    public let initialFocusedBranchShare: CGFloat?
    /// Whether the branch containing the focused pane is the split's first child.
    public let focusedBranchIsFirst: Bool?

    /// Creates a generic planned divider move with no branch-specific context.
    public init(splitId: UUID, position: CGFloat) {
        self.init(
            splitId: splitId,
            position: position,
            requestedFocusedBranchShare: nil,
            focusedBranchShare: nil,
            initialFocusedBranchShare: nil,
            focusedBranchIsFirst: nil
        )
    }

    /// Creates a branch-aware planned divider move.
    public init(
        splitId: UUID,
        position: CGFloat,
        requestedFocusedBranchShare: CGFloat?,
        focusedBranchShare: CGFloat?,
        initialFocusedBranchShare: CGFloat? = nil,
        focusedBranchIsFirst: Bool? = nil
    ) {
        self.splitId = splitId
        self.position = position
        self.requestedFocusedBranchShare = requestedFocusedBranchShare
        self.focusedBranchShare = focusedBranchShare
        self.initialFocusedBranchShare = initialFocusedBranchShare
        self.focusedBranchIsFirst = focusedBranchIsFirst
    }
}
