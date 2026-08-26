import Foundation

/// Where Claude Code agent-team `tmux new-window` teammates are created.
public enum TeamsSpawnPlacement: String, CaseIterable, Sendable, SettingCodable {
    /// Preserve tmux's cmux compatibility mapping: create a sibling workspace.
    case workspace
    /// Create a terminal surface in the caller's existing workspace and pane.
    case surface
}
