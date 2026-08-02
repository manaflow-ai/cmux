import Bonsplit
import Foundation

extension Workspace {
    func didProgrammaticallyChangeSplitGeometry() {
        splitTabBar(bonsplitController, didChangeGeometry: bonsplitController.layoutSnapshot())
    }

    func applyInitialSplitDividerPosition(
        _ position: CGFloat?,
        sourcePaneId: PaneID,
        newPaneId: PaneID
    ) {
        guard let position,
              let splitId = splitIdJoiningPaneIds(
                sourcePaneId.id.uuidString,
                newPaneId.id.uuidString,
                in: bonsplitController.treeSnapshot()
              ) else { return }
        _ = bonsplitController.setDividerPosition(position, forSplit: splitId, fromExternal: true)
    }

    private func splitIdJoiningPaneIds(
        _ firstPaneId: String,
        _ secondPaneId: String,
        in node: ExternalTreeNode
    ) -> UUID? {
        switch node {
        case .pane:
            return nil
        case .split(let splitNode):
            let firstContainsFirst = splitTreeContainsPane(firstPaneId, in: splitNode.first)
            let firstContainsSecond = splitTreeContainsPane(secondPaneId, in: splitNode.first)
            let secondContainsFirst = splitTreeContainsPane(firstPaneId, in: splitNode.second)
            let secondContainsSecond = splitTreeContainsPane(secondPaneId, in: splitNode.second)
            if (firstContainsFirst && secondContainsSecond) || (firstContainsSecond && secondContainsFirst) {
                return UUID(uuidString: splitNode.id)
            }
            return splitIdJoiningPaneIds(firstPaneId, secondPaneId, in: splitNode.first)
                ?? splitIdJoiningPaneIds(firstPaneId, secondPaneId, in: splitNode.second)
        }
    }

    private func splitTreeContainsPane(_ paneId: String, in node: ExternalTreeNode) -> Bool {
        switch node {
        case .pane(let pane):
            return pane.id == paneId
        case .split(let split):
            return splitTreeContainsPane(paneId, in: split.first)
                || splitTreeContainsPane(paneId, in: split.second)
        }
    }
}
