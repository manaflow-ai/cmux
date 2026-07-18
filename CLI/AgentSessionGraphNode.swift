import CmuxFoundation
import Foundation

/// A sanitized CLI snapshot of one agent process generation.
struct AgentSessionGraphNode: Codable, Sendable, Equatable {
    var provider: String
    var sessionId: String?
    var runId: String
    var identitySource: String
    var pid: Int?
    var processStartedAt: TimeInterval?
    var cmuxRuntime: AgentCmuxRuntimeIdentity?
    var workspaceId: String
    var surfaceId: String
    var cwd: String?
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
    var terminalObservation: CmuxAgentTerminalObservation?
    var terminalStateApplied: Bool

    /// A process generation can host more than one logical session and some
    /// providers emit hooks from the same launcher process. Graph identity must
    /// therefore include provider and session instead of treating `runId` as a
    /// globally unique node key.
    var nodeId: String {
        if let sessionId {
            return "\(provider)\u{1F}\(sessionId)\u{1F}\(runId)"
        }
        let runtime = cmuxRuntime?.id ?? terminalObservation?.runtimeID ?? "unknown"
        return "terminal\u{1F}\(runtime)\u{1F}\(surfaceId)\u{1F}\(runId)"
    }

    init(
        provider: String,
        sessionId: String?,
        runId: String,
        identitySource: String = "hook_session",
        pid: Int?,
        processStartedAt: TimeInterval?,
        cmuxRuntime: AgentCmuxRuntimeIdentity?,
        workspaceId: String,
        surfaceId: String,
        cwd: String? = nil,
        processState: AgentProcessState,
        sessionState: AgentSessionLifecycleState,
        foregroundState: AgentForegroundState,
        attentionState: AgentAttentionState,
        activity: AgentActivitySnapshot,
        effectiveState: AgentEffectiveState,
        workloads: [AgentWorkloadSnapshot],
        subtreeActivity: AgentSubtreeActivitySnapshot = AgentSubtreeActivitySnapshot(),
        restoreAuthority: Bool,
        startedAt: TimeInterval,
        updatedAt: TimeInterval,
        endedAt: TimeInterval?,
        terminalObservation: CmuxAgentTerminalObservation? = nil,
        terminalStateApplied: Bool = false
    ) {
        self.provider = provider
        self.sessionId = sessionId
        self.runId = runId
        self.identitySource = identitySource
        self.pid = pid
        self.processStartedAt = processStartedAt
        self.cmuxRuntime = cmuxRuntime
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.cwd = cwd
        self.processState = processState
        self.sessionState = sessionState
        self.foregroundState = foregroundState
        self.attentionState = attentionState
        self.activity = activity
        self.effectiveState = effectiveState
        self.workloads = workloads
        self.subtreeActivity = subtreeActivity
        self.restoreAuthority = restoreAuthority
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.endedAt = endedAt
        self.terminalObservation = terminalObservation
        self.terminalStateApplied = terminalStateApplied
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nodeId, forKey: .nodeId)
        try container.encode(provider, forKey: .provider)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(runId, forKey: .runId)
        try container.encode(identitySource, forKey: .identitySource)
        try container.encodeIfPresent(pid, forKey: .pid)
        try container.encodeIfPresent(processStartedAt, forKey: .processStartedAt)
        try container.encodeIfPresent(cmuxRuntime, forKey: .cmuxRuntime)
        try container.encode(workspaceId, forKey: .workspaceId)
        try container.encode(surfaceId, forKey: .surfaceId)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encode(processState, forKey: .processState)
        try container.encode(sessionState, forKey: .sessionState)
        try container.encode(foregroundState, forKey: .foregroundState)
        try container.encode(attentionState, forKey: .attentionState)
        try container.encode(activity, forKey: .activity)
        try container.encode(effectiveState, forKey: .effectiveState)
        try container.encode(workloads, forKey: .workloads)
        try container.encode(subtreeActivity, forKey: .subtreeActivity)
        try container.encode(restoreAuthority, forKey: .restoreAuthority)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(endedAt, forKey: .endedAt)
        try container.encodeIfPresent(terminalObservation, forKey: .terminalObservation)
        try container.encode(terminalStateApplied ? "terminal" : "lifecycle", forKey: .stateSource)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // node_id is derived from the identity fields below. Decode the source
        // fields so older persisted payloads without node_id remain compatible.
        self.init(
            provider: try container.decode(String.self, forKey: .provider),
            sessionId: try container.decodeIfPresent(String.self, forKey: .sessionId),
            runId: try container.decode(String.self, forKey: .runId),
            identitySource: try container.decodeIfPresent(String.self, forKey: .identitySource) ?? "hook_session",
            pid: try container.decodeIfPresent(Int.self, forKey: .pid),
            processStartedAt: try container.decodeIfPresent(TimeInterval.self, forKey: .processStartedAt),
            cmuxRuntime: try container.decodeIfPresent(AgentCmuxRuntimeIdentity.self, forKey: .cmuxRuntime),
            workspaceId: try container.decode(String.self, forKey: .workspaceId),
            surfaceId: try container.decode(String.self, forKey: .surfaceId),
            cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
            processState: try container.decode(AgentProcessState.self, forKey: .processState),
            sessionState: try container.decode(AgentSessionLifecycleState.self, forKey: .sessionState),
            foregroundState: try container.decode(AgentForegroundState.self, forKey: .foregroundState),
            attentionState: try container.decode(AgentAttentionState.self, forKey: .attentionState),
            activity: try container.decode(AgentActivitySnapshot.self, forKey: .activity),
            effectiveState: try container.decode(AgentEffectiveState.self, forKey: .effectiveState),
            workloads: try container.decode([AgentWorkloadSnapshot].self, forKey: .workloads),
            subtreeActivity: try container.decodeIfPresent(
                AgentSubtreeActivitySnapshot.self,
                forKey: .subtreeActivity
            ) ?? AgentSubtreeActivitySnapshot(),
            restoreAuthority: try container.decode(Bool.self, forKey: .restoreAuthority),
            startedAt: try container.decode(TimeInterval.self, forKey: .startedAt),
            updatedAt: try container.decode(TimeInterval.self, forKey: .updatedAt),
            endedAt: try container.decodeIfPresent(TimeInterval.self, forKey: .endedAt),
            terminalObservation: try container.decodeIfPresent(
                CmuxAgentTerminalObservation.self,
                forKey: .terminalObservation
            ),
            terminalStateApplied: (try container.decodeIfPresent(String.self, forKey: .stateSource)) == "terminal"
        )
    }

    enum CodingKeys: String, CodingKey {
        case nodeId = "node_id"
        case provider
        case sessionId = "session_id"
        case runId = "run_id"
        case identitySource = "identity_source"
        case pid
        case processStartedAt = "process_started_at"
        case cmuxRuntime = "cmux_runtime"
        case workspaceId = "workspace_id"
        case surfaceId = "surface_id"
        case cwd
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
        case terminalObservation = "terminal_observation"
        case stateSource = "state_source"
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

    static func prefers(_ candidate: AgentSessionGraphNode, over existing: AgentSessionGraphNode) -> Bool {
        if candidate.updatedAt != existing.updatedAt { return candidate.updatedAt > existing.updatedAt }
        if candidate.startedAt != existing.startedAt { return candidate.startedAt > existing.startedAt }
        let candidateKey = "\(candidate.provider):\(candidate.sessionId ?? ""):\(candidate.surfaceId)"
        let existingKey = "\(existing.provider):\(existing.sessionId ?? ""):\(existing.surfaceId)"
        return candidateKey < existingKey
    }
}
