import GhosttyKit

/// A semantic terminal text region that can be captured from Ghostty.
public enum TerminalTextRegion: Sendable {
    /// The currently visible viewport.
    case viewport
    /// The current terminal screen.
    case screen
    /// The complete surface history.
    case history
    /// The active screen or history region selected by Ghostty.
    case active

    var pointTag: ghostty_point_tag_e {
        switch self {
        case .viewport:
            GHOSTTY_POINT_VIEWPORT
        case .screen:
            GHOSTTY_POINT_SCREEN
        case .history:
            GHOSTTY_POINT_SURFACE
        case .active:
            GHOSTTY_POINT_ACTIVE
        }
    }
}
