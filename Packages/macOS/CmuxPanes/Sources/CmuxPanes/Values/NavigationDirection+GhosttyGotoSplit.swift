public import Bonsplit
public import GhosttyKit

extension NavigationDirection {
    /// Map a Ghostty `GHOSTTY_ACTION_GOTO_SPLIT` direction onto a Bonsplit
    /// `NavigationDirection`, returning `nil` for any unrecognized value. This is
    /// the byte-faithful home of the legacy
    /// `GhosttyApp.focusDirection(from:ghostty_action_goto_split_e)` converter
    /// that fed the runtime goto-split action.
    ///
    /// For previous/next, we use left/right as a reasonable default because
    /// Bonsplit doesn't have cycle-based navigation.
    public init?(ghosttyGotoSplit direction: ghostty_action_goto_split_e) {
        switch direction {
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
