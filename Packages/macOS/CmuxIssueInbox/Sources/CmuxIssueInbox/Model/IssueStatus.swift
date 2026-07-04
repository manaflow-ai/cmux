public import Foundation

/// Normalized open or closed state for issue providers.
public enum IssueStatus: String, Codable, Sendable, CaseIterable {
    /// The issue is active and should appear in the default inbox filter.
    case open
    /// The issue is completed, canceled, or otherwise no longer active.
    case closed
}
