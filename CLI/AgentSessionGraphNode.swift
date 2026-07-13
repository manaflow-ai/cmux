import Foundation

/// A sanitized CLI snapshot of one agent process generation.
struct AgentSessionGraphNode: Codable, Sendable, Equatable {
    var provider: String
    var sessionId: String
    var runId: String
    var pid: Int?
    var processStartedAt: TimeInterval?
    var cmuxRuntime: AgentCmuxRuntimeIdentity?
    var workspaceId: String
    var surfaceId: String
    var processState: AgentProcessState
    var sessionState: AgentSessionLifecycleState
    var foregroundState: AgentForegroundState
    var attentionState: AgentAttentionState
    var activity: AgentActivitySnapshot
    var effectiveState: AgentEffectiveState
    var workloads: [AgentWorkloadSnapshot]
    var subtreeActivity = AgentSubtreeActivitySnapshot()
    var restoreAuthority: Bool
    var startedAt: TimeInterval
    var updatedAt: TimeInterval
    var endedAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case provider
        case sessionId = "session_id"
        case runId = "run_id"
        case pid
        case processStartedAt = "process_started_at"
        case cmuxRuntime = "cmux_runtime"
        case workspaceId = "workspace_id"
        case surfaceId = "surface_id"
        case processState = "process_state"
        case sessionState = "session_state"
        case foregroundState = "foreground_state"
        case attentionState = "attention_state"
        case activity
        case effectiveState = "effective_state"
        case workloads
        case subtreeActivity = "subtree_activity"
        case restoreAuthority = "restore_authority"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case endedAt = "ended_at"
    }
}
