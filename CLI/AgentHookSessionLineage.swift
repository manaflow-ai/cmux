import Foundation

/// The bounded process-lineage result attached to one hook event.
struct AgentHookSessionLineage: Sendable, Equatable {
    var runId: String
    var pid: Int?
    var processStartedAt: TimeInterval?
    var cmuxRuntime: AgentCmuxRuntimeIdentity? = nil
    var parentRunId: String?
    var parentSessionId: String?
    var relationship: AgentSessionRelationship?
    var restoreAuthority: Bool
}
