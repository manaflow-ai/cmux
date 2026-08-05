public import CoreGraphics

/// A focused pane branch's proportional size relative to its sibling branch.
///
/// Use this value to preserve ratio intent at an input boundary, then pass
/// ``share`` to ``PaneLayoutService/setSplitShareResult(in:targetPaneId:axis:share:controller:)``.
/// For example, a `3:1` ratio produces a focused-branch share of `3/4`.
public struct PaneShareRatio: Hashable, Sendable {
    /// The number of proportional parts assigned to the focused branch.
    public let focusedParts: Int

    /// The number of proportional parts assigned to the sibling branch.
    public let siblingParts: Int

    /// Creates a positive focused-to-sibling ratio.
    ///
    /// - Parameters:
    ///   - focusedParts: The positive number of parts assigned to the focused branch.
    ///   - siblingParts: The positive number of parts assigned to the sibling branch.
    public init?(focusedParts: Int, siblingParts: Int) {
        guard focusedParts > 0, siblingParts > 0 else { return nil }
        self.focusedParts = focusedParts
        self.siblingParts = siblingParts
    }

    /// The focused branch's fractional share of the enclosing split.
    public var share: CGFloat {
        let focused = CGFloat(focusedParts)
        return focused / (focused + CGFloat(siblingParts))
    }
}
