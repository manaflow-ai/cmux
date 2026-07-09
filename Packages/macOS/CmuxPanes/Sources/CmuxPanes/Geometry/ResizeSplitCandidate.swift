public import CoreGraphics
public import Foundation

/// One split that encloses a resize target pane, as discovered by
/// ``ExternalTreeNode/collectResizeCandidates(targetPaneId:candidates:)``.
///
/// The candidate carries everything a divider resize needs: the split's id, its
/// `"horizontal"`/`"vertical"` orientation, whether the target pane sits in the
/// split's first child (so callers know which edge the divider controls), the
/// current divider position, and the split's pixel span along its resize axis
/// (clamped to a 1px floor).
public struct ResizeSplitCandidate {
    /// The Bonsplit split node's identifier.
    public let splitId: UUID
    /// The split orientation, lowercased to `"horizontal"` or `"vertical"`.
    public let orientation: String
    /// `true` when the resize target pane is in the split's first child.
    public let paneInFirstChild: Bool
    /// The split's current divider position (0-1 fraction).
    public let dividerPosition: CGFloat
    /// The split's pixel span along its resize axis, never below 1.
    public let axisPixels: CGFloat
}
