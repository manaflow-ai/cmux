public import Foundation

/// Refresh outcome for all Issue Inbox sources.
public struct IssueInboxRefreshReport: Codable, Equatable, Sendable {
    /// Per-source refresh results keyed by source ID.
    public var perSource: [String: IssueInboxRefreshSourceResult]

    /// Creates a refresh report.
    ///
    /// - Parameter perSource: Per-source refresh results keyed by source ID.
    public init(perSource: [String: IssueInboxRefreshSourceResult] = [:]) {
        self.perSource = perSource
    }
}
