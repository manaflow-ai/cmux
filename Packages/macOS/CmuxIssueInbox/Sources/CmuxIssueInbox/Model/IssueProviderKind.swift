public import Foundation

/// Identifies the upstream issue provider that supplied an inbox item.
public enum IssueProviderKind: String, Codable, Sendable, CaseIterable {
    /// GitHub Issues from a configured repository.
    case github
    /// Linear issues from a configured team.
    case linear
}
