import Foundation

/// Resolves graph edges that retain a durable parent session ID after the
/// parent process generation is no longer available to the child hook.
struct AgentSessionGraphEdgeResolver: Sendable {
    private let nodesByRunId: [String: [AgentSessionGraphNode]]
    private let parentCandidatesBySessionId: [String: [AgentSessionGraphNode]]
    private let nodesByNodeId: [String: AgentSessionGraphNode]

    init(nodes: [AgentSessionGraphNode]) {
        let canonical = AgentSessionGraphNodeIndex.canonicalNodes(nodes)
        nodesByRunId = AgentSessionGraphNodeIndex.candidatesByRunId(canonical)
        nodesByNodeId = AgentSessionGraphNodeIndex.nodes(canonical)
        parentCandidatesBySessionId = Dictionary(grouping: canonical.compactMap { node in
            node.sessionId.map { ($0, node) }
        }, by: \.0)
            .mapValues { candidates in
                candidates.map(\.1).sorted { lhs, rhs in
                    if (lhs.endedAt == nil) != (rhs.endedAt == nil) { return lhs.endedAt == nil }
                    if lhs.restoreAuthority != rhs.restoreAuthority { return lhs.restoreAuthority }
                    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                    if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
                    return lhs.runId < rhs.runId
                }
            }
    }

    func parentNodeId(for edge: AgentSessionGraphEdge) -> String? {
        if let fromRunId = edge.fromRunId,
           let candidates = nodesByRunId[fromRunId] {
            let eligible = candidates.filter { $0.nodeId != edge.toNodeId }
            if let fromSessionId = edge.fromSessionId {
                if let parent = eligible.first(where: { $0.sessionId == fromSessionId }) {
                    return parent.nodeId
                }
                // The durable session identity is stronger than a reused run
                // ID. Fall through to session-only recovery below.
            } else if eligible.count == 1 {
                return eligible[0].nodeId
            } else if let childProvider = nodesByNodeId[edge.toNodeId]?.provider {
                let sameProvider = eligible.filter { $0.provider == childProvider }
                if sameProvider.count == 1 { return sameProvider[0].nodeId }
                // Run IDs are not global. Multiple same-provider candidates,
                // or several foreign-provider candidates, are ambiguous.
                return nil
            }
        }
        guard let fromSessionId = edge.fromSessionId else { return nil }
        let candidates = parentCandidatesBySessionId[fromSessionId] ?? []
        if let childProvider = nodesByNodeId[edge.toNodeId]?.provider {
            return candidates.first(where: {
                $0.nodeId != edge.toNodeId && $0.provider == childProvider
            })?.nodeId
        }
        return candidates.first(where: { $0.nodeId != edge.toNodeId })?.nodeId
    }
}
