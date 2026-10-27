public import Foundation

/// Sessions a launch warm may retry. Successful sessions and intentional stops are excluded so
/// retrying a sibling cannot restart an agent the person stopped during launch.
public nonisolated struct AgentPaneWarmFailure: Error, Sendable {
    /// Only the sessions that failed with a retryable outcome.
    public let sessionIds: [String]
    /// Retains the failed subset for the launch coordinator.
    public init(sessionIds: [String]) { self.sessionIds = sessionIds }
}
