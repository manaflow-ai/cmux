import Foundation

/// Horizontal placement for width-capped terminal and agent-session content.
public enum SessionContentAlignment: String, CaseIterable, Sendable, SettingCodable {
    /// Place capped content against the left edge of the pane.
    case left
    /// Center capped content in the pane.
    case center
    /// Place capped content against the right edge of the pane.
    case right
}
