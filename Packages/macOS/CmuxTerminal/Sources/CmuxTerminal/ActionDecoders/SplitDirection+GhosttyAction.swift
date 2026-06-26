public import CmuxPanes
public import GhosttyKit

extension SplitDirection {
    /// Decodes a libghostty `new_split` action direction into the Bonsplit-facing
    /// ``SplitDirection``, returning `nil` for any unrecognized value.
    ///
    /// Byte-faithful home of the legacy `GhosttyApp.splitDirection(from:)` mapper:
    /// the terminal runtime resolves a `GHOSTTY_ACTION_NEW_SPLIT` event's
    /// direction through this single source of truth before creating the split.
    public init?(ghosttySplitDirection direction: ghostty_action_split_direction_e) {
        switch direction {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: self = .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: self = .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: self = .down
        case GHOSTTY_SPLIT_DIRECTION_UP: self = .up
        default: return nil
        }
    }
}
