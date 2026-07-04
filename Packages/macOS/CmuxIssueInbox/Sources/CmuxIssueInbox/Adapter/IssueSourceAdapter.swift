public import Foundation

/// Fetches normalized issues for one configured issue source.
public protocol IssueSourceAdapter: Sendable {
    /// Stable identifier for this configured source.
    var sourceID: String { get }
    /// Human-readable source label.
    var displayName: String { get }

    /// Fetches the current issues for this source.
    ///
    /// - Returns: Normalized issue inbox items.
    /// - Throws: ``IssueSourceError`` or a transport error when the provider cannot be fetched.
    func fetchIssues() async throws -> [IssueInboxItem]
}
