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

/// Duplicate-safe run lookup for corrupted or hand-edited session stores.
/// The newest node wins, with a stable identity key breaking timestamp ties.
struct AgentSessionGraphNodeIndex: Sendable {
    static func indices(_ nodes: [AgentSessionGraphNode]) -> [String: Int] {
        nodes.indices.reduce(into: [:]) { result, candidateIndex in
            let runId = nodes[candidateIndex].runId
            guard let existingIndex = result[runId] else {
                result[runId] = candidateIndex
                return
            }
            if prefers(nodes[candidateIndex], over: nodes[existingIndex]) {
                result[runId] = candidateIndex
            }
        }
    }

    static func nodes(_ nodes: [AgentSessionGraphNode]) -> [String: AgentSessionGraphNode] {
        indices(nodes).mapValues { nodes[$0] }
    }

    static func canonicalNodes(_ nodes: [AgentSessionGraphNode]) -> [AgentSessionGraphNode] {
        indices(nodes).values.sorted().map { nodes[$0] }
    }

    private static func prefers(_ candidate: AgentSessionGraphNode, over existing: AgentSessionGraphNode) -> Bool {
        if candidate.updatedAt != existing.updatedAt { return candidate.updatedAt > existing.updatedAt }
        if candidate.startedAt != existing.startedAt { return candidate.startedAt > existing.startedAt }
        let candidateKey = "\(candidate.provider):\(candidate.sessionId):\(candidate.surfaceId)"
        let existingKey = "\(existing.provider):\(existing.sessionId):\(existing.surfaceId)"
        return candidateKey < existingKey
    }
}
