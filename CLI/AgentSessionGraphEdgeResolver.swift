import Foundation

/// Resolves graph edges that retain a durable parent session ID after the
/// parent process generation is no longer available to the child hook.
struct AgentSessionGraphEdgeResolver: Sendable {
    private struct ProviderRunKey: Hashable, Sendable {
        var provider: String
        var runID: String
    }

    private struct ProviderRunSessionKey: Hashable, Sendable {
        var provider: String
        var runID: String
        var sessionID: String
    }

    private struct ProviderSessionKey: Hashable, Sendable {
        var provider: String
        var sessionID: String
    }

    private struct RunSessionKey: Hashable, Sendable {
        var runID: String
        var sessionID: String
    }

    private struct NodeIdentity: Sendable {
        var provider: String
        var sessionID: String?
        var runID: String
    }

    /// Stores only the two preferred node IDs needed by child exclusion. Input
    /// is already preference-ordered, avoiding arrays of copied graph nodes.
    private struct CandidateSummary: Sendable {
        private(set) var count = 0
        private var firstNodeID: String?
        private var secondNodeID: String?

        mutating func insertInPreferenceOrder(_ nodeID: String) {
            count += 1
            if firstNodeID == nil {
                firstNodeID = nodeID
            } else if secondNodeID == nil {
                secondNodeID = nodeID
            }
        }

        func firstNodeID(excluding nodeID: String) -> String? {
            firstNodeID == nodeID ? secondNodeID : firstNodeID
        }

        func uniqueNodeID(excluding nodeID: String, containsExcludedNode: Bool) -> String? {
            guard count - (containsExcludedNode ? 1 : 0) == 1 else { return nil }
            return firstNodeID(excluding: nodeID)
        }
    }

    private let candidatesByProviderRun: [ProviderRunKey: CandidateSummary]
    private let candidatesByProviderRunSession: [ProviderRunSessionKey: CandidateSummary]
    private let parentCandidatesByProviderSession: [ProviderSessionKey: CandidateSummary]
    private let candidatesByRun: [String: CandidateSummary]
    private let candidatesByRunSession: [RunSessionKey: CandidateSummary]
    private let parentCandidatesBySession: [String: CandidateSummary]
    private let nodesByNodeID: [String: NodeIdentity]
    private let nodeIndex: AgentSessionGraphNodeIndex
    private let graphOrdering: AgentSessionGraphOrdering

    init(
        nodes: [AgentSessionGraphNode],
        nodeIndex: AgentSessionGraphNodeIndex = AgentSessionGraphNodeIndex(),
        graphOrdering: AgentSessionGraphOrdering = AgentSessionGraphOrdering()
    ) {
        self.nodeIndex = nodeIndex
        self.graphOrdering = graphOrdering
        let nodeIDs = nodes.map(\.nodeId)
        var canonicalIndexByNodeID: [String: Int] = [:]
        canonicalIndexByNodeID.reserveCapacity(nodes.count)
        for index in nodes.indices {
            let nodeID = nodeIDs[index]
            guard let existing = canonicalIndexByNodeID[nodeID] else {
                canonicalIndexByNodeID[nodeID] = index
                continue
            }
            if nodeIndex.prefers(nodes[index], over: nodes[existing]) {
                canonicalIndexByNodeID[nodeID] = index
            }
        }
        let canonicalIndices = canonicalIndexByNodeID.values.sorted()
        var mutableNodesByNodeID: [String: NodeIdentity] = [:]
        mutableNodesByNodeID.reserveCapacity(canonicalIndices.count)
        for index in canonicalIndices {
            let node = nodes[index]
            mutableNodesByNodeID[nodeIDs[index]] = NodeIdentity(
                provider: node.provider,
                sessionID: node.sessionId,
                runID: node.runId
            )
        }
        nodesByNodeID = mutableNodesByNodeID

        let runOrderedIndices = canonicalIndices.sorted { lhsIndex, rhsIndex in
            let lhs = nodes[lhsIndex]
            let rhs = nodes[rhsIndex]
            if nodeIndex.prefers(lhs, over: rhs) { return true }
            if nodeIndex.prefers(rhs, over: lhs) { return false }
            return nodeIDs[lhsIndex] < nodeIDs[rhsIndex]
        }
        var byProviderRun: [ProviderRunKey: CandidateSummary] = [:]
        var byProviderRunSession: [ProviderRunSessionKey: CandidateSummary] = [:]
        var byRun: [String: CandidateSummary] = [:]
        var byRunSession: [RunSessionKey: CandidateSummary] = [:]
        byProviderRun.reserveCapacity(runOrderedIndices.count)
        byProviderRunSession.reserveCapacity(runOrderedIndices.count)
        byRun.reserveCapacity(runOrderedIndices.count)
        byRunSession.reserveCapacity(runOrderedIndices.count)
        for index in runOrderedIndices {
            let node = nodes[index]
            let nodeID = nodeIDs[index]
            byProviderRun[ProviderRunKey(provider: node.provider, runID: node.runId), default: CandidateSummary()]
                .insertInPreferenceOrder(nodeID)
            byRun[node.runId, default: CandidateSummary()].insertInPreferenceOrder(nodeID)
            if let sessionID = node.sessionId {
                byProviderRunSession[ProviderRunSessionKey(
                    provider: node.provider,
                    runID: node.runId,
                    sessionID: sessionID
                ), default: CandidateSummary()]
                    .insertInPreferenceOrder(nodeID)
                byRunSession[RunSessionKey(
                    runID: node.runId,
                    sessionID: sessionID
                ), default: CandidateSummary()]
                    .insertInPreferenceOrder(nodeID)
            }
        }
        candidatesByProviderRun = byProviderRun
        candidatesByProviderRunSession = byProviderRunSession
        candidatesByRun = byRun
        candidatesByRunSession = byRunSession

        let sessionOrderedIndices = canonicalIndices.sorted { lhsIndex, rhsIndex in
            Self.sessionParentPrecedes(nodes[lhsIndex], nodes[rhsIndex])
        }
        var byProviderSession: [ProviderSessionKey: CandidateSummary] = [:]
        var bySession: [String: CandidateSummary] = [:]
        byProviderSession.reserveCapacity(sessionOrderedIndices.count)
        bySession.reserveCapacity(sessionOrderedIndices.count)
        for index in sessionOrderedIndices {
            let node = nodes[index]
            guard let sessionID = node.sessionId else { continue }
            byProviderSession[ProviderSessionKey(
                provider: node.provider,
                sessionID: sessionID
            ), default: CandidateSummary()]
                .insertInPreferenceOrder(nodeIDs[index])
            bySession[sessionID, default: CandidateSummary()]
                .insertInPreferenceOrder(nodeIDs[index])
        }
        parentCandidatesByProviderSession = byProviderSession
        parentCandidatesBySession = bySession
    }

    func parentNodeId(for edge: AgentSessionGraphEdge) -> String? {
        guard let child = nodesByNodeID[edge.toNodeId] else { return nil }
        if let fromRunID = edge.fromRunId {
            let runMatchesChild = child.runID == fromRunID
            if let fromSessionID = edge.fromSessionId {
                let exactCandidates = candidatesByProviderRunSession[ProviderRunSessionKey(
                    provider: child.provider,
                    runID: fromRunID,
                    sessionID: fromSessionID
                )]
                if let parentNodeID = exactCandidates?.firstNodeID(excluding: edge.toNodeId) {
                    return parentNodeID
                }
                // The durable session identity is stronger than a reused run
                // ID. Fall through to session-only recovery below.
                let sameProviderSession = parentCandidatesByProviderSession[ProviderSessionKey(
                    provider: child.provider,
                    sessionID: fromSessionID
                )]
                if let parentNodeID = sameProviderSession?.firstNodeID(excluding: edge.toNodeId) {
                    return parentNodeID
                }
                let sessionMatchesChild = child.sessionID == fromSessionID
                if let parentNodeID = candidatesByRunSession[RunSessionKey(
                    runID: fromRunID,
                    sessionID: fromSessionID
                )]?.uniqueNodeID(
                    excluding: edge.toNodeId,
                    containsExcludedNode: runMatchesChild && sessionMatchesChild
                ) {
                    return parentNodeID
                }
                return parentCandidatesBySession[fromSessionID]?.uniqueNodeID(
                    excluding: edge.toNodeId,
                    containsExcludedNode: sessionMatchesChild
                )
            } else {
                let sameProvider = candidatesByProviderRun[ProviderRunKey(
                    provider: child.provider,
                    runID: fromRunID
                )]
                if let parentNodeID = sameProvider?.uniqueNodeID(
                    excluding: edge.toNodeId,
                    containsExcludedNode: runMatchesChild
                ) {
                    return parentNodeID
                }
                return candidatesByRun[fromRunID]?.uniqueNodeID(
                    excluding: edge.toNodeId,
                    containsExcludedNode: runMatchesChild
                )
            }
        }
        guard let fromSessionID = edge.fromSessionId else { return nil }
        let sameProvider = parentCandidatesByProviderSession[ProviderSessionKey(
            provider: child.provider,
            sessionID: fromSessionID
        )]
        if let parentNodeID = sameProvider?.firstNodeID(excluding: edge.toNodeId) {
            return parentNodeID
        }
        return parentCandidatesBySession[fromSessionID]?.uniqueNodeID(
            excluding: edge.toNodeId,
            containsExcludedNode: child.sessionID == fromSessionID
        )
    }

    private static func sessionParentPrecedes(
        _ lhs: AgentSessionGraphNode,
        _ rhs: AgentSessionGraphNode
    ) -> Bool {
        if (lhs.endedAt == nil) != (rhs.endedAt == nil) { return lhs.endedAt == nil }
        if lhs.restoreAuthority != rhs.restoreAuthority { return lhs.restoreAuthority }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        if lhs.runId != rhs.runId { return lhs.runId < rhs.runId }
        return lhs.nodeId < rhs.nodeId
    }
}

/// Converts persisted parent claims into the single-parent, acyclic graph that
/// the CLI contract exposes. A process generation has one durable parent; when
/// corrupt history supplies several, the first edge in canonical output order
/// wins. Missing parents and self-parents are ignored. For every remaining
/// cycle, removing the edge owned by its greatest node ID makes the same node a
/// root regardless of input or dictionary iteration order.
struct AgentSessionGraphEdgeSanitizer: Sendable {
    private struct ResolvedEdge: Sendable {
        var edge: AgentSessionGraphEdge
        var parentNodeIndex: Int
        var childNodeIndex: Int
    }

    private let nodeIndex: AgentSessionGraphNodeIndex
    private let graphOrdering: AgentSessionGraphOrdering

    init(
        nodeIndex: AgentSessionGraphNodeIndex = AgentSessionGraphNodeIndex(),
        graphOrdering: AgentSessionGraphOrdering = AgentSessionGraphOrdering()
    ) {
        self.nodeIndex = nodeIndex
        self.graphOrdering = graphOrdering
    }

    func acyclicEdges(
        nodes: [AgentSessionGraphNode],
        edges: [AgentSessionGraphEdge]
    ) -> [AgentSessionGraphEdge] {
        guard !nodes.isEmpty, !edges.isEmpty else { return [] }

        let indexByNodeID = nodeIndex.indices(nodes)
        let resolver = AgentSessionGraphEdgeResolver(
            nodes: nodes,
            nodeIndex: nodeIndex,
            graphOrdering: graphOrdering
        )
        var resolvedEdges: [ResolvedEdge] = []
        resolvedEdges.reserveCapacity(edges.count)
        for edge in edges {
            guard let parentNodeID = resolver.parentNodeId(for: edge),
                  let parentNodeIndex = indexByNodeID[parentNodeID],
                  let childNodeIndex = indexByNodeID[edge.toNodeId],
                  parentNodeIndex != childNodeIndex else {
                continue
            }
            resolvedEdges.append(ResolvedEdge(
                edge: edge,
                parentNodeIndex: parentNodeIndex,
                childNodeIndex: childNodeIndex
            ))
        }
        resolvedEdges.sort { lhs, rhs in
            if graphOrdering.edgePrecedes(lhs.edge, rhs.edge) { return true }
            if graphOrdering.edgePrecedes(rhs.edge, lhs.edge) { return false }
            let lhsParentNodeID = nodes[lhs.parentNodeIndex].nodeId
            let rhsParentNodeID = nodes[rhs.parentNodeIndex].nodeId
            if lhsParentNodeID != rhsParentNodeID { return lhsParentNodeID < rhsParentNodeID }
            return lhs.childNodeIndex < rhs.childNodeIndex
        }

        var edgeByChildNodeIndex: [Int: ResolvedEdge] = [:]
        edgeByChildNodeIndex.reserveCapacity(resolvedEdges.count)
        for resolvedEdge in resolvedEdges where edgeByChildNodeIndex[resolvedEdge.childNodeIndex] == nil {
            edgeByChildNodeIndex[resolvedEdge.childNodeIndex] = resolvedEdge
        }

        let parentByChildNodeIndex = edgeByChildNodeIndex.mapValues(\.parentNodeIndex)
        var visitState = Array(repeating: UInt8(0), count: nodes.count)
        var positionInPath = Array(repeating: -1, count: nodes.count)
        var removedChildNodeIndices: Set<Int> = []
        let traversalOrder = nodes.indices.sorted { nodes[$0].nodeId < nodes[$1].nodeId }
        for startNodeIndex in traversalOrder where visitState[startNodeIndex] == 0 {
            var path: [Int] = []
            var currentNodeIndex: Int? = startNodeIndex
            while let nodeIndex = currentNodeIndex, visitState[nodeIndex] == 0 {
                visitState[nodeIndex] = 1
                positionInPath[nodeIndex] = path.count
                path.append(nodeIndex)
                currentNodeIndex = parentByChildNodeIndex[nodeIndex]
            }
            if let nodeIndex = currentNodeIndex,
               visitState[nodeIndex] == 1,
               positionInPath[nodeIndex] >= 0 {
                let cycleStart = positionInPath[nodeIndex]
                let childNodeIndexToRemove = path[cycleStart...].max {
                    nodes[$0].nodeId < nodes[$1].nodeId
                }
                if let childNodeIndexToRemove {
                    removedChildNodeIndices.insert(childNodeIndexToRemove)
                }
            }
            for nodeIndex in path {
                visitState[nodeIndex] = 2
                positionInPath[nodeIndex] = -1
            }
        }

        return edgeByChildNodeIndex.values
            .filter { !removedChildNodeIndices.contains($0.childNodeIndex) }
            .map(\.edge)
            .sorted(by: graphOrdering.edgePrecedes)
    }
}
