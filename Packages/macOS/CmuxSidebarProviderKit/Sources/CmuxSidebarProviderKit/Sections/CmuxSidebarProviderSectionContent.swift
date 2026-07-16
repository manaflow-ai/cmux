import Foundation

/// Host-rendered content a sidebar provider can place inside a tree section.
public enum CmuxSidebarProviderSectionContent: String, Codable, Equatable, Sendable {
    /// Git-authoritative worktree management for the section's project root.
    case projectWorktrees = "project-worktrees"
}
