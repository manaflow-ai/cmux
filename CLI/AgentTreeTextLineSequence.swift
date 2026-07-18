import Foundation

/// Streams the text tree one line at a time so deep or large histories do not
/// require a second full rendered copy in memory.
struct AgentTreeTextLineSequence: Sequence {
    let snapshot: AgentSessionGraphSnapshot
    let maximumDepth: Int

    func makeIterator() -> Iterator {
        Iterator(snapshot: snapshot, maximumDepth: maximumDepth)
    }

    struct Iterator: IteratorProtocol {
        private struct ResolvedEdgeKey: Hashable {
            let parentNodeID: String
            let childNodeID: String
        }

        private struct RenderFrame {
            var node: AgentSessionGraphNode
            var prefix: String
            var connector: String
            var depth: Int
        }

        private let maximumDepth: Int
        private let childrenByNodeID: [String: [AgentSessionGraphNode]]
        private let roots: [AgentSessionGraphNode]
        private let nodes: [AgentSessionGraphNode]
        private var nextRootIndex = 0
        private var nextFallbackIndex = 0
        private var stack: [RenderFrame] = []
        private var visited: Set<String> = []
        private var covered: Set<String> = []

        init(snapshot: AgentSessionGraphSnapshot, maximumDepth: Int) {
            self.maximumDepth = maximumDepth
            nodes = snapshot.nodes
            let nodeByID = AgentSessionGraphNodeIndex.nodes(snapshot.nodes)
            let edgeResolver = AgentSessionGraphEdgeResolver(nodes: snapshot.nodes)
            var seenEdgeKeys: Set<ResolvedEdgeKey> = []
            let resolvedEdges = snapshot.edges.compactMap {
                edge -> (parentNodeID: String, edge: AgentSessionGraphEdge)? in
                guard let parentNodeID = edgeResolver.parentNodeId(for: edge),
                      seenEdgeKeys.insert(ResolvedEdgeKey(
                          parentNodeID: parentNodeID,
                          childNodeID: edge.toNodeId
                      )).inserted else { return nil }
                return (parentNodeID, edge)
            }
            let childEdgesByNodeID = Dictionary(
                grouping: resolvedEdges,
                by: \.parentNodeID
            ).mapValues { $0.map(\.edge) }
            childrenByNodeID = childEdgesByNodeID.mapValues { edges in
                edges.compactMap { nodeByID[$0.toNodeId] }
            }
            let childNodeIDs = Set(resolvedEdges.map { $0.edge.toNodeId })
            roots = snapshot.nodes.filter { !childNodeIDs.contains($0.nodeId) }
        }

        mutating func next() -> String? {
            while true {
                if stack.isEmpty, !seedNextTraversal() { return nil }
                guard let frame = stack.popLast() else { continue }
                let node = frame.node
                guard frame.depth <= maximumDepth,
                      visited.insert(node.nodeId).inserted else {
                    continue
                }

                let children = childrenByNodeID[node.nodeId] ?? []
                let childPrefix = frame.prefix
                    + (frame.connector == "├── " ? "│   " : frame.connector == "└── " ? "    " : "")
                for index in children.indices.reversed() {
                    stack.append(RenderFrame(
                        node: children[index],
                        prefix: childPrefix,
                        connector: index == children.count - 1 ? "└── " : "├── ",
                        depth: frame.depth + 1
                    ))
                }
                return Self.line(for: node, prefix: frame.prefix, connector: frame.connector)
            }
        }

        private mutating func seedNextTraversal() -> Bool {
            while nextRootIndex < roots.count {
                let root = roots[nextRootIndex]
                nextRootIndex += 1
                guard !covered.contains(root.nodeId) else { continue }
                markReachable(from: root)
                stack.append(RenderFrame(node: root, prefix: "", connector: "", depth: 0))
                return true
            }
            while nextFallbackIndex < nodes.count {
                let node = nodes[nextFallbackIndex]
                nextFallbackIndex += 1
                guard !covered.contains(node.nodeId) else { continue }
                // Components made entirely of cycles have no root. Mark the
                // whole component before rendering its fallback seed so a
                // depth-truncated descendant cannot later reappear as a root.
                markReachable(from: node)
                stack.append(RenderFrame(node: node, prefix: "", connector: "", depth: 0))
                return true
            }
            return false
        }

        private mutating func markReachable(from root: AgentSessionGraphNode) {
            var pending = [root]
            while let node = pending.popLast() {
                guard covered.insert(node.nodeId).inserted else { continue }
                pending.append(contentsOf: childrenByNodeID[node.nodeId] ?? [])
            }
        }

        private static func line(
            for node: AgentSessionGraphNode,
            prefix: String,
            connector: String
        ) -> String {
            let authority: String
            if node.identitySource == "terminal_process" {
                authority = " process"
            } else {
                authority = node.restoreAuthority ? " restore-owner" : " child"
            }
            let modes = node.activity.modes.map(\.rawValue).joined(separator: ",")
            let activity = modes.isEmpty ? "" : " [\(modes)]"
            let identity = node.sessionId ?? "pid \(node.pid.map(String.init) ?? "unknown")"
            let location = "workspace:\(node.workspaceId) surface:\(node.surfaceId)"
            let workingDirectory = node.cwd.map { " cwd:\($0)" } ?? ""
            return "\(prefix)\(connector)\(node.provider) \(identity) \(node.effectiveState.rawValue.uppercased())\(activity)\(authority) \(location)\(workingDirectory)"
        }
    }
}
