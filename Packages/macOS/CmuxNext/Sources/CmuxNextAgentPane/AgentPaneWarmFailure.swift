public import Foundation

/// Sessions that could not be confirmed restored. Successful siblings remain independent.
public nonisolated struct AgentPaneWarmFailure: Error, Sendable {
    public let sessionIds: [String]
    public init(sessionIds: [String]) { self.sessionIds = sessionIds }
}
