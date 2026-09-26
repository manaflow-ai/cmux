public import Bonsplit
import Foundation

/// Finds the adjacent pane that browser and file opens should reuse before creating a split.
@MainActor
public struct BrowserSplitPaneResolver {
    /// Creates a resolver for live Bonsplit pane geometry.
    public init() {}

    /// Returns the nearest reusable pane in the requested split direction.
    ///
    /// - Parameters:
    ///   - sourcePane: The pane whose adjacent sibling should be found.
    ///   - controller: The live Bonsplit controller that owns `sourcePane`.
    ///   - orientation: The split axis whose second branch is the destination.
    /// - Returns: The preferred adjacent pane, or `nil` when the source pane or
    ///     its geometry cannot be resolved.
    public func preferredPane(
        from sourcePane: PaneID,
        in controller: BonsplitController,
        orientation: SplitOrientation = .horizontal
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
        let sourceCenterX = sourceFrame.x + (sourceFrame.width * 0.5)
        let sourceCenterY = sourceFrame.y + (sourceFrame.height * 0.5)
        let sourceEdgeX = sourceFrame.x + sourceFrame.width
        let sourceEdgeY = sourceFrame.y + sourceFrame.height
        let paneById = Dictionary(uniqueKeysWithValues: controller.allPaneIds.map { ($0.id, $0) })

        for crumb in path {
            guard crumb.split.orientation == orientation.rawValue, crumb.sourceIsFirst else { continue }
            var candidateNodes: [ExternalPaneNode] = []
            collectPaneNodes(node: crumb.split.second, into: &candidateNodes)
            if candidateNodes.isEmpty { continue }

            let sorted = candidateNodes.sorted { lhs, rhs in
                let lhsCenterX = lhs.frame.x + (lhs.frame.width * 0.5)
                let rhsCenterX = rhs.frame.x + (rhs.frame.width * 0.5)
                let lhsCenterY = lhs.frame.y + (lhs.frame.height * 0.5)
                let rhsCenterY = rhs.frame.y + (rhs.frame.height * 0.5)
                let lhsPrimaryDistance: Double
                let rhsPrimaryDistance: Double
                let lhsSecondaryDistance: Double
                let rhsSecondaryDistance: Double
                let lhsSecondaryPosition: Double
                let rhsSecondaryPosition: Double
                switch orientation {
                case .horizontal:
                    lhsPrimaryDistance = abs(lhsCenterY - sourceCenterY)
                    rhsPrimaryDistance = abs(rhsCenterY - sourceCenterY)
                    lhsSecondaryDistance = abs(lhs.frame.x - sourceEdgeX)
                    rhsSecondaryDistance = abs(rhs.frame.x - sourceEdgeX)
                    lhsSecondaryPosition = lhs.frame.x
                    rhsSecondaryPosition = rhs.frame.x
                case .vertical:
                    lhsPrimaryDistance = abs(lhsCenterX - sourceCenterX)
                    rhsPrimaryDistance = abs(rhsCenterX - sourceCenterX)
                    lhsSecondaryDistance = abs(lhs.frame.y - sourceEdgeY)
                    rhsSecondaryDistance = abs(rhs.frame.y - sourceEdgeY)
                    lhsSecondaryPosition = lhs.frame.y
                    rhsSecondaryPosition = rhs.frame.y
                }
                if lhsPrimaryDistance != rhsPrimaryDistance { return lhsPrimaryDistance < rhsPrimaryDistance }
                if lhsSecondaryDistance != rhsSecondaryDistance { return lhsSecondaryDistance < rhsSecondaryDistance }
                if lhsSecondaryPosition != rhsSecondaryPosition {
                    return lhsSecondaryPosition < rhsSecondaryPosition
                }
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

/// Backwards-compatible name for callers that only need the default right-side search.
@available(*, deprecated, renamed: "BrowserSplitPaneResolver")
public typealias BrowserRightSidePaneResolver = BrowserSplitPaneResolver
