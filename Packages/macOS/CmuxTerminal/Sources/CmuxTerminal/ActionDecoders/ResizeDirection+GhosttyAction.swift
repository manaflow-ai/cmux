public import CmuxPanes
public import GhosttyKit

extension ResizeDirection {
    /// Decodes a libghostty `resize_split` action direction into the
    /// Bonsplit-facing ``ResizeDirection``, returning `nil` for any unrecognized
    /// value.
    ///
    /// Byte-faithful home of the legacy `GhosttyApp.resizeDirection(from:)` mapper:
    /// the terminal runtime resolves a `GHOSTTY_ACTION_RESIZE_SPLIT` event's
    /// direction through this single source of truth before moving the divider.
    public init?(ghosttyResizeSplit direction: ghostty_action_resize_split_direction_e) {
        switch direction {
        case GHOSTTY_RESIZE_SPLIT_UP: self = .up
        case GHOSTTY_RESIZE_SPLIT_DOWN: self = .down
        case GHOSTTY_RESIZE_SPLIT_LEFT: self = .left
        case GHOSTTY_RESIZE_SPLIT_RIGHT: self = .right
        default: return nil
        }
    }
}
