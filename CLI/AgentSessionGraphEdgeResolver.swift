import Foundation

/// Resolves graph edges that retain a durable parent session ID after the
/// parent process generation is no longer available to the child hook.
struct AgentSessionGraphEdgeResolver: Sendable {
    private let nodesByRunId: [String: AgentSessionGraphNode]
    private let parentCandidatesBySessionId: [String: [AgentSessionGraphNode]]

    init(nodes: [AgentSessionGraphNode]) {
        let canonical = AgentSessionGraphNodeIndex.canonicalNodes(nodes)
        nodesByRunId = AgentSessionGraphNodeIndex.nodes(canonical)
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

    func parentRunId(for edge: AgentSessionGraphEdge) -> String? {
        if let fromRunId = edge.fromRunId, nodesByRunId[fromRunId] != nil {
            return fromRunId
        }
        guard let fromSessionId = edge.fromSessionId else { return nil }
        return parentCandidatesBySessionId[fromSessionId]?
            .first(where: { $0.runId != edge.toRunId })?
            .runId
    }
}
