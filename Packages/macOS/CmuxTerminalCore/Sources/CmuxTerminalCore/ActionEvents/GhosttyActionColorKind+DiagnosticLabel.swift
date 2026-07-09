public import GhosttyKit

extension ghostty_action_color_kind_e {
    /// The short, stable label for a libghostty color-change kind, used in the
    /// terminal's background diagnostic log.
    ///
    /// A pure classifier on the kind enum itself: the three named color slots
    /// map to their lowercase names and any palette index falls back to
    /// `palette:<index>`, so app- and surface-scoped color-change log lines
    /// share one source of truth.
    public var diagnosticLabel: String {
        switch self {
        case GHOSTTY_ACTION_COLOR_KIND_FOREGROUND:
            return "foreground"
        case GHOSTTY_ACTION_COLOR_KIND_BACKGROUND:
            return "background"
        case GHOSTTY_ACTION_COLOR_KIND_CURSOR:
            return "cursor"
        default:
            return "palette:\(rawValue)"
        }
    }
}
