import Foundation

/// Descendant-only activity. A parent's own state remains in `activity` and
/// `effective_state`; this rollup answers whether any nested agents are active.
struct AgentSubtreeActivitySnapshot: Codable, Sendable, Equatable {
    var totalDescendants = 0
    var busyDescendants = 0
    var restoreOwners = 0
    var needsInput = 0
    var errors = 0
    var working = 0
    var monitoring = 0
    var scheduled = 0
    var interrupted = 0
    var hibernated = 0
    var ended = 0
    var workloadCounts = AgentActivitySnapshot.Counts()

    enum CodingKeys: String, CodingKey {
        case totalDescendants = "total_descendants"
        case busyDescendants = "busy_descendants"
        case restoreOwners = "restore_owners"
        case needsInput = "needs_input"
        case errors
        case working
        case monitoring
        case scheduled
        case interrupted
        case hibernated
        case ended
        case workloadCounts = "workload_counts"
    }

    mutating func add(node: AgentSessionGraphNode) {
        totalDescendants += 1
        if node.activity.busy { busyDescendants += 1 }
        if node.restoreAuthority { restoreOwners += 1 }
        switch node.effectiveState {
        case .needsInput: needsInput += 1
        case .error: errors += 1
        case .working: working += 1
        case .monitoring: monitoring += 1
        case .scheduled: scheduled += 1
        case .interrupted: interrupted += 1
        case .hibernated: hibernated += 1
        case .ended: ended += 1
        case .idle, .restoring, .unknown: break
        }
        workloadCounts.add(node.activity.counts)
    }

    mutating func add(_ other: AgentSubtreeActivitySnapshot) {
        totalDescendants += other.totalDescendants
        busyDescendants += other.busyDescendants
        restoreOwners += other.restoreOwners
        needsInput += other.needsInput
        errors += other.errors
        working += other.working
        monitoring += other.monitoring
        scheduled += other.scheduled
        interrupted += other.interrupted
        hibernated += other.hibernated
        ended += other.ended
        workloadCounts.add(other.workloadCounts)
    }
}

extension AgentActivitySnapshot.Counts {
    mutating func add(_ other: Self) {
        foreground += other.foreground
        backgroundTerminal += other.backgroundTerminal
        monitor += other.monitor
        scheduled += other.scheduled
        subagent += other.subagent
        tool += other.tool
        self.other += other.other
    }
}

/// Computes descendant rollups from leaves to roots in O(nodes + edges). Cycles
/// are ignored instead of recursing or blocking the CLI on corrupt history.
struct AgentSubtreeActivityProjector: Sendable {
    private struct EdgeKey: Hashable, Sendable {
        var parent: Int
        var child: Int
    }

    func project(nodes: inout [AgentSessionGraphNode], edges: [AgentSessionGraphEdge]) {
        var indexByNode = AgentSessionGraphNodeIndex.indices(nodes)
        if indexByNode.count != nodes.count {
            nodes = indexByNode.values.sorted().map { nodes[$0] }
            indexByNode = AgentSessionGraphNodeIndex.indices(nodes)
        }
        let edgeResolver = AgentSessionGraphEdgeResolver(nodes: nodes)
        var parentsByChild: [Int: [Int]] = [:]
        var remainingChildren = Array(repeating: 0, count: nodes.count)
        var seenEdges: Set<EdgeKey> = []
        for edge in edges {
            guard let parentNode = edgeResolver.parentNodeId(for: edge),
                  let parent = indexByNode[parentNode],
                  let child = indexByNode[edge.toNodeId],
                  parent != child else { continue }
            let edgeKey = EdgeKey(parent: parent, child: child)
            guard seenEdges.insert(edgeKey).inserted else { continue }
            parentsByChild[child, default: []].append(parent)
            remainingChildren[parent] += 1
        }

        var queue = nodes.indices.filter { remainingChildren[$0] == 0 }
        var cursor = 0
        while cursor < queue.count {
            let child = queue[cursor]
            cursor += 1
            for parent in parentsByChild[child] ?? [] {
                nodes[parent].subtreeActivity.add(node: nodes[child])
                nodes[parent].subtreeActivity.add(nodes[child].subtreeActivity)
                remainingChildren[parent] -= 1
                if remainingChildren[parent] == 0 { queue.append(parent) }
            }
        }
    }
}
