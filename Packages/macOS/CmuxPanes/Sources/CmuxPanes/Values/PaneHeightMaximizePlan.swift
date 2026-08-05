public import CoreGraphics
public import Foundation

/// A set of exact vertical split extents that gives one pane the available height.
public struct PaneHeightMaximizePlan: Equatable, Sendable {
    /// An imposed first-child extent for one vertical split.
    public struct Adjustment: Equatable, Sendable {
        /// The split whose first child receives the imposed extent.
        public let splitId: UUID
        /// The exact first-child extent in points.
        public let imposedFirstExtent: CGFloat

        /// Creates an exact extent adjustment.
        public init(splitId: UUID, imposedFirstExtent: CGFloat) {
            self.splitId = splitId
            self.imposedFirstExtent = imposedFirstExtent
        }
    }

    /// The outermost-to-innermost vertical adjustments.
    public let adjustments: [Adjustment]

    /// Creates a height-maximize plan.
    public init(adjustments: [Adjustment]) {
        self.adjustments = adjustments
    }
}

/// The result of calculating a height-maximize plan from split-tree geometry.
public enum PaneHeightMaximizePlanResult: Equatable, Sendable {
    /// A complete plan that can be applied to the live Bonsplit controller.
    case plan(PaneHeightMaximizePlan)
    /// The requested pane is not inside a height split.
    case noMatchingSplit
    /// A vertical split required for the plan cannot be addressed.
    case invalidSplitIdentifier
    /// The competing pane headers do not fit in the available height.
    case insufficientHeight
}
