public import Bonsplit
public import GhosttyKit

extension NavigationDirection {
    /// Decodes a libghostty `goto_split` action target into the Bonsplit
    /// ``NavigationDirection``, returning `nil` for any unrecognized value.
    ///
    /// Byte-faithful home of the legacy `GhosttyApp.focusDirection(from:)` mapper.
    /// Bonsplit has no cycle-based navigation, so `previous`/`next` map to
    /// `left`/`right` as the legacy reasonable default; the four cardinal targets
    /// map directly.
    public init?(ghosttyGotoSplit direction: ghostty_action_goto_split_e) {
        switch direction {
        // For previous/next, we use left/right as a reasonable default
        // Bonsplit doesn't have cycle-based navigation
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: self = .left
        case GHOSTTY_GOTO_SPLIT_NEXT: self = .right
        case GHOSTTY_GOTO_SPLIT_UP: self = .up
        case GHOSTTY_GOTO_SPLIT_DOWN: self = .down
        case GHOSTTY_GOTO_SPLIT_LEFT: self = .left
        case GHOSTTY_GOTO_SPLIT_RIGHT: self = .right
        default: return nil
        }
    }
}
