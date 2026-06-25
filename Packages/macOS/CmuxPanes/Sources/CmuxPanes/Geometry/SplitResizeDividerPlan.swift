public import CoreGraphics
public import Foundation

/// One planned divider resize: the split to adjust plus the divider position
/// before and after the move. Unlike ``SplitDividerAdjustment`` (which carries
/// only the target position for the position-only equalize/keyboard apply), a
/// resize reports its prior position so a caller can echo the old/new divider
/// positions in its result payload, matching the legacy `pane.resize` wire.
public struct SplitResizeDividerPlan: Equatable, Sendable {
    /// The split whose divider moves.
    public let splitId: UUID
    /// The normalized (0.0-1.0) divider position before the move.
    public let oldPosition: CGFloat
    /// The normalized (0.0-1.0) divider position after the clamped move.
    public let newPosition: CGFloat

    /// Creates a planned divider resize.
    public init(splitId: UUID, oldPosition: CGFloat, newPosition: CGFloat) {
        self.splitId = splitId
        self.oldPosition = oldPosition
        self.newPosition = newPosition
    }
}

/// The outcome of planning a relative (keyboard/delta) divider resize: either a
/// concrete ``SplitResizeDividerPlan`` or the specific reason no divider could
/// be planned. The cases mirror the distinct legacy `pane.resize` relative
/// failures so the caller maps each one to its own result without re-walking
/// the tree.
public enum RelativeResizeDividerPlan: Equatable, Sendable {
    /// A divider move was planned.
    case planned(SplitResizeDividerPlan)
    /// The target pane was not present anywhere in the split tree.
    case paneNotFound
    /// No enclosing split matched the resize direction's axis.
    case noOrientationSplitAncestor
    /// A split matched the axis, but none had the target on the controlling
    /// child side for the requested direction.
    case noAdjacentBorder
}
