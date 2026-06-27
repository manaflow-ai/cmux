public import CoreGraphics

/// Resize direction for backwards compatibility.
///
/// The raw value is the wire token (`"left"`/`"right"`/`"up"`/`"down"`) so a
/// caller maps an inbound string straight to a case via `init(rawValue:)`.
public enum ResizeDirection: String, Sendable {
    /// Move the controlling divider left.
    case left
    /// Move the controlling divider right.
    case right
    /// Move the controlling divider up.
    case up
    /// Move the controlling divider down.
    case down

    /// The orientation string of the split whose divider this resize moves
    /// (matches `ExternalSplitNode.orientation`).
    public var splitOrientation: String {
        switch self {
        case .left, .right:
            return "horizontal"
        case .up, .down:
            return "vertical"
        }
    }

    /// A split controls the target pane's right/bottom edge when the target is
    /// the first child, and left/top edge when the target is the second child.
    public var requiresPaneInFirstChild: Bool {
        switch self {
        case .right, .down:
            return true
        case .left, .up:
            return false
        }
    }

    /// Positive values move the divider toward the second child (right/down).
    public var dividerDeltaSign: CGFloat {
        requiresPaneInFirstChild ? 1 : -1
    }
}
