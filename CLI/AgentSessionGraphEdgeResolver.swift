import Foundation

/// Resolves graph edges that retain a durable parent session ID after the
/// parent process generation is no longer available to the child hook.
struct AgentSessionGraphEdgeResolver: Sendable {
    private struct CandidateSummary: Sendable {
        let count: Int
        let firstNodeId: String
        let secondNodeId: String?

        init(_ candidates: [AgentSessionGraphNode]) {
            precondition(!candidates.isEmpty)
            count = candidates.count
            firstNodeId = candidates[0].nodeId
            secondNodeId = candidates.count > 1 ? candidates[1].nodeId : nil
        }

        func firstNodeId(excluding nodeId: String) -> String? {
            firstNodeId == nodeId ? secondNodeId : firstNodeId
        }
    }

    private struct RunCandidateSummary: Sendable {
        let all: CandidateSummary
        let bySessionId: [String: CandidateSummary]
        let byProvider: [String: CandidateSummary]

        init(_ candidates: [AgentSessionGraphNode]) {
            all = CandidateSummary(candidates)
            bySessionId = Dictionary(grouping: candidates.compactMap { node in
                node.sessionId.map { ($0, node) }
            }, by: \.0).mapValues { CandidateSummary($0.map(\.1)) }
            byProvider = Dictionary(grouping: candidates, by: \.provider)
                .mapValues(CandidateSummary.init)
        }
    }

    private struct SessionCandidateSummary: Sendable {
        let all: CandidateSummary
        let byProvider: [String: CandidateSummary]

        init(_ candidates: [AgentSessionGraphNode]) {
            all = CandidateSummary(candidates)
            byProvider = Dictionary(grouping: candidates, by: \.provider)
                .mapValues(CandidateSummary.init)
        }
    }

    private let candidatesByRunId: [String: RunCandidateSummary]
    private let parentCandidatesBySessionId: [String: SessionCandidateSummary]
    private let nodesByNodeId: [String: AgentSessionGraphNode]

    init(nodes: [AgentSessionGraphNode]) {
        let canonical = AgentSessionGraphNodeIndex.canonicalNodes(nodes)
        candidatesByRunId = AgentSessionGraphNodeIndex.candidatesByRunId(canonical)
            .mapValues(RunCandidateSummary.init)
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
                    if lhs.runId != rhs.runId { return lhs.runId < rhs.runId }
                    return lhs.nodeId < rhs.nodeId
                }
            }
            .mapValues(SessionCandidateSummary.init)
    }

    func parentNodeId(for edge: AgentSessionGraphEdge) -> String? {
        if let fromRunId = edge.fromRunId,
           let candidates = candidatesByRunId[fromRunId] {
            let child = nodesByNodeId[edge.toNodeId]
            let excludesChild = child?.runId == fromRunId
            if let fromSessionId = edge.fromSessionId {
                if let parentNodeId = candidates.bySessionId[fromSessionId]?
                    .firstNodeId(excluding: edge.toNodeId) {
                    return parentNodeId
                }
                // The durable session identity is stronger than a reused run
                // ID. Fall through to session-only recovery below.
            } else if candidates.all.count - (excludesChild ? 1 : 0) == 1 {
                return candidates.all.firstNodeId(excluding: edge.toNodeId)
            } else if let childProvider = child?.provider {
                if let sameProvider = candidates.byProvider[childProvider],
                   sameProvider.count - (excludesChild ? 1 : 0) == 1 {
                    return sameProvider.firstNodeId(excluding: edge.toNodeId)
                }
                // Run IDs are not global. Multiple same-provider candidates,
                // or several foreign-provider candidates, are ambiguous.
                return nil
            }
        }
        guard let fromSessionId = edge.fromSessionId else { return nil }
        guard let candidates = parentCandidatesBySessionId[fromSessionId] else { return nil }
        if let childProvider = nodesByNodeId[edge.toNodeId]?.provider {
            return candidates.byProvider[childProvider]?.firstNodeId(excluding: edge.toNodeId)
        }
        return candidates.all.firstNodeId(excluding: edge.toNodeId)
    }
}
