/// The mirrored Mac surface kind represented by a pane tab.
public enum MobileWorkspaceTabKind: String, Codable, Equatable, Sendable {
    /// A Ghostty terminal surface.
    case terminal
    /// A Mac-owned browser surface.
    case browser
}
