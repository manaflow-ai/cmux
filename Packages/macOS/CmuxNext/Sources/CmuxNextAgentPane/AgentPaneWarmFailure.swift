public import Foundation

/// The launch sessions whose agent could not be confirmed restored.
public nonisolated struct AgentPaneWarmFailure: Error, Sendable {
    /// Session identifiers that reported a failed or ambiguous warm operation.
    public let sessionIds: [String]

    /// Creates a failure for the sessions that need user-visible reporting or cleanup.
    public init(sessionIds: [String]) { self.sessionIds = sessionIds }
}
