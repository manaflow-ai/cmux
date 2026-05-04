import Bonsplit
import CoreGraphics
import Foundation

extension TabManager {
    /// Equalize splits - not directly supported by bonsplit.
    func equalizeSplits(tabId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }

        let didEqualize = equalizeSplitsOnce(in: tab)
        if didEqualize {
            tab.didProgrammaticallyChangeSplitGeometry()
            scheduleEqualizeSplitsFollowUp(tabId: tabId)
        }
        return didEqualize
    }

    @discardableResult
    private func equalizeSplitsOnce(in tab: Workspace) -> Bool {
        var foundSplit = false
        var allSucceeded = true
        equalizeSplits(
            in: tab.bonsplitController.treeSnapshot(),
            controller: tab.bonsplitController,
            foundSplit: &foundSplit,
            allSucceeded: &allSucceeded
        )
        return foundSplit && allSucceeded
    }

    private func scheduleEqualizeSplitsFollowUp(tabId: UUID) {
        DispatchQueue.main.async { [weak self] in
            self?.runEqualizeSplitsFollowUp(tabId: tabId)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.runEqualizeSplitsFollowUp(tabId: tabId)
        }
    }

    private func runEqualizeSplitsFollowUp(tabId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        if equalizeSplitsOnce(in: tab) {
            tab.didProgrammaticallyChangeSplitGeometry()
        }
    }

    private func equalizeSplits(
        in node: ExternalTreeNode,
        controller: BonsplitController,
        foundSplit: inout Bool,
        allSucceeded: inout Bool
    ) {
        switch node {
        case .pane:
            return
        case .split(let splitNode):
            foundSplit = true
            guard let splitId = UUID(uuidString: splitNode.id) else {
                allSucceeded = false
                return
            }

            if !controller.setDividerPosition(0.5, forSplit: splitId) {
                allSucceeded = false
            }

            equalizeSplits(
                in: splitNode.first,
                controller: controller,
                foundSplit: &foundSplit,
                allSucceeded: &allSucceeded
            )
            equalizeSplits(
                in: splitNode.second,
                controller: controller,
                foundSplit: &foundSplit,
                allSucceeded: &allSucceeded
            )
        }
    }
}
