public import Foundation

/// Status filter applied to Issue Inbox rows.
public enum IssueInboxStatusFilter: String, Sendable, CaseIterable {
    /// Show open issues.
    case open
    /// Show closed issues.
    case closed
    /// Show issues in every status.
    case all
}
