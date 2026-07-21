public import Bonsplit
import Foundation

/// Finds the right-side pane that browser and file opens should reuse before
/// creating another horizontal split.
@MainActor
public struct BrowserRightSidePaneResolver {
    /// Creates a resolver for live Bonsplit pane geometry.
    public init() {}

    /// Returns the nearest reusable pane to the right of a source pane.
    ///
    /// - Parameters:
    ///   - sourcePane: The pane whose nearest right-side sibling should be found.
    ///   - controller: The live Bonsplit controller that owns `sourcePane`.
    /// - Returns: The preferred right-side pane, or `nil` when the source pane or
    ///   its geometry cannot be resolved.
    public func preferredPane(
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
        guard let sourceFrame = paneFrameById[sourcePaneId] else { return nil }
        let sourceCenterY = sourceFrame.y + (sourceFrame.height * 0.5)
        let sourceRightX = sourceFrame.x + sourceFrame.width
        let paneById = Dictionary(uniqueKeysWithValues: controller.allPaneIds.map { ($0.id, $0) })

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
                      let pane = paneById[candidateUUID] else {
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
