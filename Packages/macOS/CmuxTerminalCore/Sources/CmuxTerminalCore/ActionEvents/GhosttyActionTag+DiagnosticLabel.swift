public import GhosttyKit

extension ghostty_action_tag_e {
    /// The short, stable label for a libghostty action tag, used in the
    /// terminal's background diagnostic log.
    ///
    /// A pure classifier on the tag enum itself: the known tags map to their
    /// snake-case wire names and any other tag falls back to its Swift
    /// description, so the action-event log line reads identically regardless
    /// of which surface or app target emits it.
    public var diagnosticLabel: String {
        switch self {
        case GHOSTTY_ACTION_RELOAD_CONFIG:
            return "reload_config"
        case GHOSTTY_ACTION_CONFIG_CHANGE:
            return "config_change"
        case GHOSTTY_ACTION_COLOR_CHANGE:
            return "color_change"
        default:
            return String(describing: self)
        }
    }
}
