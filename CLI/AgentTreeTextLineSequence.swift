import Foundation

/// Streams the text tree one line at a time so deep or large histories do not
/// require a second full rendered copy in memory.
struct AgentTreeTextLineSequence: Sequence {
    let snapshot: AgentSessionGraphSnapshot
    let maximumDepth: Int
    let nodeIndex = AgentSessionGraphNodeIndex()

    func makeIterator() -> Iterator {
        Iterator(snapshot: snapshot, maximumDepth: maximumDepth, nodeIndex: nodeIndex)
    }

    struct Iterator: IteratorProtocol {
        private struct ResolvedEdgeKey: Hashable {
            let parentNodeIndex: Int
            let childNodeIndex: Int
        }

        private struct RenderFrame {
            var nodeIndex: Int
            var relationship: AgentSessionRelationship?
            var prefix: String
            var connector: String
            var depth: Int
        }

        private struct Child {
            var nodeIndex: Int
            var relationship: AgentSessionRelationship
        }

        private let maximumDepth: Int
        private let childrenByNodeIndex: [Int: [Child]]
        private let roots: [Int]
        private let nodes: [AgentSessionGraphNode]
        private var nextRootIndex = 0
        private var nextFallbackIndex = 0
        private var stack: [RenderFrame] = []
        private var visited: Set<Int> = []
        private var covered: Set<Int> = []

        init(
            snapshot: AgentSessionGraphSnapshot,
            maximumDepth: Int,
            nodeIndex: AgentSessionGraphNodeIndex
        ) {
            self.maximumDepth = maximumDepth
            nodes = snapshot.nodes
            guard !snapshot.edges.isEmpty else {
                childrenByNodeIndex = [:]
                roots = Array(snapshot.nodes.indices)
                return
            }
            let indexByNodeID = nodeIndex.indices(snapshot.nodes)
            let edgeResolver = AgentSessionGraphEdgeResolver(
                nodes: snapshot.nodes,
                nodeIndex: nodeIndex
            )
            var seenEdgeKeys: Set<ResolvedEdgeKey> = []
            var mutableChildrenByNodeIndex: [Int: [Child]] = [:]
            var childNodeIndices: Set<Int> = []
            for edge in snapshot.edges {
                guard let parentNodeID = edgeResolver.parentNodeId(for: edge),
                      let parentNodeIndex = indexByNodeID[parentNodeID],
                      let childNodeIndex = indexByNodeID[edge.toNodeId],
                      seenEdgeKeys.insert(ResolvedEdgeKey(
                          parentNodeIndex: parentNodeIndex,
                          childNodeIndex: childNodeIndex
                      )).inserted else { continue }
                mutableChildrenByNodeIndex[parentNodeIndex, default: []].append(Child(
                    nodeIndex: childNodeIndex,
                    relationship: edge.relationship
                ))
                childNodeIndices.insert(childNodeIndex)
            }
            childrenByNodeIndex = mutableChildrenByNodeIndex
            roots = snapshot.nodes.indices.filter { !childNodeIndices.contains($0) }
        }

        mutating func next() -> String? {
            while true {
                if stack.isEmpty, !seedNextTraversal() { return nil }
                guard let frame = stack.popLast() else { continue }
                let node = nodes[frame.nodeIndex]
                guard frame.depth <= maximumDepth,
                      visited.insert(frame.nodeIndex).inserted else {
                    continue
                }

                let children = childrenByNodeIndex[frame.nodeIndex] ?? []
                let childPrefix = frame.prefix
                    + (frame.connector == "├── " ? "│   " : frame.connector == "└── " ? "    " : "")
                for index in children.indices.reversed() {
                    stack.append(RenderFrame(
                        nodeIndex: children[index].nodeIndex,
                        relationship: children[index].relationship,
                        prefix: childPrefix,
                        connector: index == children.count - 1 ? "└── " : "├── ",
                        depth: frame.depth + 1
                    ))
                }
                return Self.line(
                    for: node,
                    relationship: frame.relationship,
                    prefix: frame.prefix,
                    connector: frame.connector
                )
            }
        }

        private mutating func seedNextTraversal() -> Bool {
            while nextRootIndex < roots.count {
                let rootIndex = roots[nextRootIndex]
                nextRootIndex += 1
                guard !covered.contains(rootIndex) else { continue }
                markReachable(from: rootIndex)
                stack.append(RenderFrame(
                    nodeIndex: rootIndex,
                    relationship: nil,
                    prefix: "",
                    connector: "",
                    depth: 0
                ))
                return true
            }
            while nextFallbackIndex < nodes.count {
                let nodeIndex = nextFallbackIndex
                nextFallbackIndex += 1
                guard !covered.contains(nodeIndex) else { continue }
                // Components made entirely of cycles have no root. Mark the
                // whole component before rendering its fallback seed so a
                // depth-truncated descendant cannot later reappear as a root.
                markReachable(from: nodeIndex)
                stack.append(RenderFrame(
                    nodeIndex: nodeIndex,
                    relationship: nil,
                    prefix: "",
                    connector: "",
                    depth: 0
                ))
                return true
            }
            return false
        }

        private mutating func markReachable(from root: Int) {
            var pending = [root]
            while let nodeIndex = pending.popLast() {
                guard covered.insert(nodeIndex).inserted else { continue }
                pending.append(contentsOf: (childrenByNodeIndex[nodeIndex] ?? []).map(\.nodeIndex))
            }
        }

        private static func line(
            for node: AgentSessionGraphNode,
            relationship: AgentSessionRelationship?,
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
            let relationshipLabel = relationship.map { "\($0.rawValue) " } ?? ""
            return "\(prefix)\(connector)\(relationshipLabel)\(node.provider) \(identity) \(node.effectiveState.rawValue.uppercased())\(activity)\(authority) \(location)\(workingDirectory)"
        }
    }
}
