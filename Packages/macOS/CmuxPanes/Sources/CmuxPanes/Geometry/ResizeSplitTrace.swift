import CoreGraphics

/// The recursive result of walking a split subtree while collecting resize
/// candidates: whether the target pane was found in the subtree and the
/// subtree's combined pixel bounds (used to size each enclosing split's axis).
public struct ResizeSplitTrace {
    /// `true` when the resize target pane lives somewhere in this subtree.
    public let containsTarget: Bool
    /// The union of this subtree's pane frames in pixels.
    let bounds: CGRect
}
