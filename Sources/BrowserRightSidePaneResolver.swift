import Bonsplit
import Foundation

/// Finds the right-side pane that browser and file opens should reuse before
/// creating another horizontal split.
struct BrowserRightSidePaneResolver {
    func preferredPane(
        from sourcePane: PaneID,
        in controller: BonsplitController
    ) -> PaneID? {
        let sourcePaneId = sourcePane.id.uuidString
        guard let path = pathToPane(
            targetPaneId: sourcePaneId,
            node: controller.treeSnapshot()
        ) else {
            return nil
        }

        let layout = controller.layoutSnapshot()
        let paneFrameById = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneId, $0.frame) })
        let sourceFrame = paneFrameById[sourcePaneId]
        let sourceCenterY = sourceFrame.map { $0.y + ($0.height * 0.5) } ?? 0
        let sourceRightX = sourceFrame.map { $0.x + $0.width } ?? 0

        for crumb in path {
            guard crumb.split.orientation == "horizontal", crumb.sourceIsFirst else { continue }
            var candidateNodes: [ExternalPaneNode] = []
            collectPaneNodes(node: crumb.split.second, into: &candidateNodes)
            if candidateNodes.isEmpty { continue }

            let sorted = candidateNodes.sorted { lhs, rhs in
                let lhsDy = abs((lhs.frame.y + (lhs.frame.height * 0.5)) - sourceCenterY)
                let rhsDy = abs((rhs.frame.y + (rhs.frame.height * 0.5)) - sourceCenterY)
                if lhsDy != rhsDy { return lhsDy < rhsDy }

                let lhsDx = abs(lhs.frame.x - sourceRightX)
                let rhsDx = abs(rhs.frame.x - sourceRightX)
                if lhsDx != rhsDx { return lhsDx < rhsDx }

                if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
                return lhs.id < rhs.id
            }

            for candidate in sorted {
                guard let candidateUUID = UUID(uuidString: candidate.id),
                      candidateUUID != sourcePane.id,
                      let pane = controller.allPaneIds.first(where: { $0.id == candidateUUID }) else {
                    continue
                }
                return pane
            }
        }

        return nil
    }

    private func pathToPane(
        targetPaneId: String,
        node: ExternalTreeNode
    ) -> [(split: ExternalSplitNode, sourceIsFirst: Bool)]? {
        switch node {
        case .pane(let paneNode):
            return paneNode.id == targetPaneId ? [] : nil
        case .split(let splitNode):
            if var path = pathToPane(targetPaneId: targetPaneId, node: splitNode.first) {
                path.append((split: splitNode, sourceIsFirst: true))
                return path
            }
            if var path = pathToPane(targetPaneId: targetPaneId, node: splitNode.second) {
                path.append((split: splitNode, sourceIsFirst: false))
                return path
            }
            return nil
        }
    }

    private func collectPaneNodes(
        node: ExternalTreeNode,
        into output: inout [ExternalPaneNode]
    ) {
        switch node {
        case .pane(let paneNode):
            output.append(paneNode)
        case .split(let splitNode):
            collectPaneNodes(node: splitNode.first, into: &output)
            collectPaneNodes(node: splitNode.second, into: &output)
        }
    }
}
