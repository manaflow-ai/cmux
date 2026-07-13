import Foundation

/// One process generation of a logical agent session.
struct AgentSessionRunRecord: Codable, Sendable, Equatable {
    var runId: String
    var pid: Int?
    var processStartedAt: TimeInterval?
    var parentRunId: String?
    var parentSessionId: String?
    var relationship: AgentSessionRelationship?
    var restoreAuthority: Bool
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
    var endedAt: TimeInterval?
}
