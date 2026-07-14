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

    /// A process generation can host more than one logical session and some
    /// providers emit hooks from the same launcher process. Graph identity must
    /// therefore include provider and session instead of treating `runId` as a
    /// globally unique node key.
    var nodeId: String {
        "\(provider)\u{1F}\(sessionId)\u{1F}\(runId)"
    }

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

/// Duplicate-safe node lookup for corrupted or hand-edited session stores.
/// The newest copy of the same provider/session/run wins. Distinct logical
/// sessions sharing one process generation remain separate graph nodes.
struct AgentSessionGraphNodeIndex: Sendable {
    static func indices(_ nodes: [AgentSessionGraphNode]) -> [String: Int] {
        nodes.indices.reduce(into: [:]) { result, candidateIndex in
            let nodeId = nodes[candidateIndex].nodeId
            guard let existingIndex = result[nodeId] else {
                result[nodeId] = candidateIndex
                return
            }
            if prefers(nodes[candidateIndex], over: nodes[existingIndex]) {
                result[nodeId] = candidateIndex
            }
        }
    }

    static func nodes(_ nodes: [AgentSessionGraphNode]) -> [String: AgentSessionGraphNode] {
        indices(nodes).mapValues { nodes[$0] }
    }

    static func canonicalNodes(_ nodes: [AgentSessionGraphNode]) -> [AgentSessionGraphNode] {
        indices(nodes).values.sorted().map { nodes[$0] }
    }

    static func candidatesByRunId(_ nodes: [AgentSessionGraphNode]) -> [String: [AgentSessionGraphNode]] {
        Dictionary(grouping: canonicalNodes(nodes), by: \.runId).mapValues { candidates in
            candidates.sorted { prefers($0, over: $1) }
        }
    }

    private static func prefers(_ candidate: AgentSessionGraphNode, over existing: AgentSessionGraphNode) -> Bool {
        if candidate.updatedAt != existing.updatedAt { return candidate.updatedAt > existing.updatedAt }
        if candidate.startedAt != existing.startedAt { return candidate.startedAt > existing.startedAt }
        let candidateKey = "\(candidate.provider):\(candidate.sessionId):\(candidate.surfaceId)"
        let existingKey = "\(existing.provider):\(existing.sessionId):\(existing.surfaceId)"
        return candidateKey < existingKey
    }
}
