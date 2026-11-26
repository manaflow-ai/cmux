public import CoreGraphics
public import Foundation

/// One planned divider move: the split to adjust and the normalized
/// (0.0-1.0) divider position to set on it.
public struct SplitDividerAdjustment: Equatable, Sendable {
    /// The split whose divider moves.
    public let splitId: UUID
    /// The normalized divider position to set.
    public let position: CGFloat

    /// Creates a planned divider move.
    public init(splitId: UUID, position: CGFloat) {
        self.splitId = splitId
        self.position = position
    }
}
