public import CoreGraphics
public import GhosttyKit

/// Resize direction for backwards compatibility.
public enum ResizeDirection: Sendable {
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

    /// Map a Ghostty `GHOSTTY_ACTION_RESIZE_SPLIT` direction onto the
    /// `ResizeDirection`, returning `nil` for any unrecognized value. This is the
    /// byte-faithful home of the legacy
    /// `GhosttyApp.resizeDirection(from:ghostty_action_resize_split_direction_e)`
    /// converter that fed the runtime resize-split action.
    public init?(ghosttyDirection direction: ghostty_action_resize_split_direction_e) {
        switch direction {
        case GHOSTTY_RESIZE_SPLIT_UP: self = .up
        case GHOSTTY_RESIZE_SPLIT_DOWN: self = .down
        case GHOSTTY_RESIZE_SPLIT_LEFT: self = .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT: self = .right
        default: return nil
        }
    }
}
