import CMUXWorkstream
import Observation

@MainActor
@Observable
final class FeedAgentTreeController {
    var collapsedNodeIds: Set<String> = []
    private(set) var selectedNodeId: String?
    private(set) var scrollRequest: FeedAgentTreeScrollRequest?
    @ObservationIgnored private var scrollRequestSequence = 0

    func toggle(_ nodeId: String) {
        if collapsedNodeIds.contains(nodeId) {
            collapsedNodeIds.remove(nodeId)
        } else {
            collapsedNodeIds.insert(nodeId)
        }
    }

    func visibleSnapshot(from graph: WorkstreamAgentGraphSnapshot) -> FeedAgentTreeVisibleSnapshot {
        FeedAgentTreeVisibleSnapshot(
            graph: graph,
            collapsedNodeIds: collapsedNodeIds
        )
    }

    func reconcileSelection(with visibleSnapshot: FeedAgentTreeVisibleSnapshot) {
        guard let selectedNodeId,
              !visibleSnapshot.focusTargets.contains(where: { $0.nodeId == selectedNodeId })
        else { return }
        self.selectedNodeId = nil
    }

    func focusFirst(
        in targets: [FeedAgentTreeFocusTarget],
        focusHost: Bool
    ) -> FeedAgentTreeSelectionEffect? {
        guard let target = preferredTarget(in: targets) else { return nil }
        return select(target, focusFeed: focusHost)
    }

    func move(
        in targets: [FeedAgentTreeFocusTarget],
        delta: Int
    ) -> FeedAgentTreeSelectionEffect? {
        guard !targets.isEmpty else { return nil }
        let nodeIds = targets.map(\.nodeId)
        let targetIndex: Int
        if let selectedNodeId,
           let currentIndex = nodeIds.firstIndex(of: selectedNodeId) {
            targetIndex = min(max(currentIndex + delta, 0), nodeIds.count - 1)
        } else {
            if selectedNodeId != nil {
                self.selectedNodeId = nil
            }
            targetIndex = delta >= 0 ? 0 : nodeIds.count - 1
        }
        return select(targets[targetIndex], focusFeed: false)
    }

    func activate(
        in targets: [FeedAgentTreeFocusTarget]
    ) -> FeedAgentTreeSelectionEffect? {
        guard let target = activationTarget(in: targets),
              let focusWorkstreamId = target.focusWorkstreamId
        else { return nil }
        var effect = select(target, focusFeed: true)
        effect.jumpWorkstreamId = focusWorkstreamId
        return effect
    }

    func select(
        _ node: WorkstreamAgentTreeNode,
        focusFeed: Bool
    ) -> FeedAgentTreeSelectionEffect {
        select(FeedAgentTreeFocusTarget(node: node), focusFeed: focusFeed)
    }

    private func select(
        _ target: FeedAgentTreeFocusTarget,
        focusFeed: Bool
    ) -> FeedAgentTreeSelectionEffect {
        selectedNodeId = target.nodeId
        scrollRequestSequence &+= 1
        let request = FeedAgentTreeScrollRequest(
            nodeId: target.nodeId,
            sequence: scrollRequestSequence
        )
        scrollRequest = request
        return FeedAgentTreeSelectionEffect(
            nodeId: target.nodeId,
            focusHost: focusFeed,
            scrollRequest: request,
            jumpWorkstreamId: nil
        )
    }

    private func preferredTarget(
        in targets: [FeedAgentTreeFocusTarget]
    ) -> FeedAgentTreeFocusTarget? {
        if let selectedNodeId,
           let target = targets.first(where: { $0.nodeId == selectedNodeId }) {
            return target
        }
        return targets.first
    }

    private func activationTarget(
        in targets: [FeedAgentTreeFocusTarget]
    ) -> FeedAgentTreeFocusTarget? {
        guard let selectedNodeId else {
            return targets.first
        }
        return targets.first { $0.nodeId == selectedNodeId }
    }
}

struct FeedAgentTreeSelectionEffect: Equatable {
    let nodeId: String
    let focusHost: Bool
    let scrollRequest: FeedAgentTreeScrollRequest
    var jumpWorkstreamId: String?
}

struct FeedAgentTreeVisibleSnapshot: Equatable {
    let rows: [FeedAgentTreeRow]
    let focusTargets: [FeedAgentTreeFocusTarget]

    static let empty = FeedAgentTreeVisibleSnapshot(rows: [], focusTargets: [])

    init(rows: [FeedAgentTreeRow], focusTargets: [FeedAgentTreeFocusTarget]) {
        self.rows = rows
        self.focusTargets = focusTargets
    }

    init(
        graph: WorkstreamAgentGraphSnapshot,
        collapsedNodeIds: Set<String>
    ) {
        var rows: [FeedAgentTreeRow] = []
        var focusTargets: [FeedAgentTreeFocusTarget] = []
        for root in graph.roots {
            Self.append(
                node: root,
                depth: 0,
                collapsedNodeIds: collapsedNodeIds,
                rows: &rows,
                focusTargets: &focusTargets
            )
        }
        self.rows = rows
        self.focusTargets = focusTargets
    }

    private static func append(
        node: WorkstreamAgentTreeNode,
        depth: Int,
        collapsedNodeIds: Set<String>,
        rows: inout [FeedAgentTreeRow],
        focusTargets: inout [FeedAgentTreeFocusTarget]
    ) {
        rows.append(FeedAgentTreeRow(node: node, depth: depth))
        focusTargets.append(FeedAgentTreeFocusTarget(node: node))
        guard !collapsedNodeIds.contains(node.id) else { return }
        for child in node.children {
            append(
                node: child,
                depth: depth + 1,
                collapsedNodeIds: collapsedNodeIds,
                rows: &rows,
                focusTargets: &focusTargets
            )
        }
    }
}

struct FeedAgentTreeFocusTarget: Equatable {
    let nodeId: String
    let focusWorkstreamId: String?

    init(node: WorkstreamAgentTreeNode) {
        self.nodeId = node.id
        self.focusWorkstreamId = node.focusWorkstreamId
    }
}

struct FeedAgentTreeScrollRequest: Equatable {
    let nodeId: String
    let sequence: Int
}
