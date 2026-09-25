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
              let splitId = splitNodeJoiningPaneIds(
                sourcePaneId.id.uuidString,
                newPaneId.id.uuidString,
                in: bonsplitController.treeSnapshot()
              ).flatMap({ UUID(uuidString: $0.id) }) else { return }
        _ = bonsplitController.setDividerPosition(position, forSplit: splitId, fromExternal: true)
        // The divider moved after bonsplit's didSplitPane projection; re-derive
        // the provisional pane frames from the same pre-split base.
        applyProvisionalSplitPaneGeometry(originalPane: sourcePaneId, newPane: newPaneId)
    }

    /// The split whose two subtrees separate `firstPaneId` from `secondPaneId`.
    func splitNodeJoiningPaneIds(
        _ firstPaneId: String,
        _ secondPaneId: String,
        in node: ExternalTreeNode
    ) -> ExternalSplitNode? {
        switch node {
        case .pane:
            return nil
        case .split(let splitNode):
            let firstContainsFirst = splitTreeContainsPane(firstPaneId, in: splitNode.first)
            let firstContainsSecond = splitTreeContainsPane(secondPaneId, in: splitNode.first)
            let secondContainsFirst = splitTreeContainsPane(firstPaneId, in: splitNode.second)
            let secondContainsSecond = splitTreeContainsPane(secondPaneId, in: splitNode.second)
            if (firstContainsFirst && secondContainsSecond) || (firstContainsSecond && secondContainsFirst) {
                return splitNode
            }
            return splitNodeJoiningPaneIds(firstPaneId, secondPaneId, in: splitNode.first)
                ?? splitNodeJoiningPaneIds(firstPaneId, secondPaneId, in: splitNode.second)
        }
    }

    func splitTreeContainsPane(_ paneId: String, in node: ExternalTreeNode) -> Bool {
        switch node {
        case .pane(let pane):
            return pane.id == paneId
        case .split(let split):
            return splitTreeContainsPane(paneId, in: split.first)
                || splitTreeContainsPane(paneId, in: split.second)
        }
    }
}
