import Foundation

/// Resolves graph edges that retain a durable parent session ID after the
/// parent process generation is no longer available to the child hook.
struct AgentSessionGraphEdgeResolver: Sendable {
    private let nodesByRunId: [String: [AgentSessionGraphNode]]
    private let parentCandidatesBySessionId: [String: [AgentSessionGraphNode]]

    init(nodes: [AgentSessionGraphNode]) {
        let canonical = AgentSessionGraphNodeIndex.canonicalNodes(nodes)
        nodesByRunId = AgentSessionGraphNodeIndex.candidatesByRunId(canonical)
        parentCandidatesBySessionId = Dictionary(grouping: canonical, by: \.sessionId)
            .mapValues { candidates in
                candidates.sorted { lhs, rhs in
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
           let candidates = nodesByRunId[fromRunId],
           let parent = candidates.first(where: { candidate in
               candidate.nodeId != edge.toNodeId
                   && (edge.fromSessionId == nil || candidate.sessionId == edge.fromSessionId)
           }) ?? candidates.first(where: { $0.nodeId != edge.toNodeId }) {
            return parent.nodeId
        }
        guard let fromSessionId = edge.fromSessionId else { return nil }
        return parentCandidatesBySessionId[fromSessionId]?
            .first(where: { $0.nodeId != edge.toNodeId })?
            .nodeId
    }
}
