public import Foundation

/// Loads Issue Inbox configuration from a testable source.
public protocol IssueInboxConfigLoading: Sendable {
    /// Loads and parses configuration.
    ///
    /// - Returns: Parsed configuration plus non-fatal warnings.
    /// - Throws: File or top-level JSON errors that prevent reading the config.
    func loadIssueInboxConfig() throws -> IssueInboxConfigLoadResult
}
