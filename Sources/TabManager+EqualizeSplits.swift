import Bonsplit
import CoreGraphics
import Foundation

extension TabManager {
    /// Equalize splits - not directly supported by bonsplit.
    func equalizeSplits(tabId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }

        let result = equalizeSplitsOnce(in: tab)
        if result.foundSplit {
            tab.didProgrammaticallyChangeSplitGeometry()
            scheduleEqualizeSplitsFollowUp(tabId: tabId)
        }
        return result.didFullyEqualize
    }

    @discardableResult
    private func equalizeSplitsOnce(in tab: Workspace) -> EqualizeSplitsResult {
        var foundSplit = false
        var allSucceeded = true
        equalizeSplits(
            in: tab.bonsplitController.treeSnapshot(),
            controller: tab.bonsplitController,
            foundSplit: &foundSplit,
            allSucceeded: &allSucceeded
        )
        return EqualizeSplitsResult(foundSplit: foundSplit, allSucceeded: allSucceeded)
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
        if equalizeSplitsOnce(in: tab).foundSplit {
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
            if let splitId = UUID(uuidString: splitNode.id) {
                if !controller.setDividerPosition(0.5, forSplit: splitId, fromExternal: true) {
                    allSucceeded = false
                }
            } else {
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

    private struct EqualizeSplitsResult {
        let foundSplit: Bool
        let allSucceeded: Bool

        var didFullyEqualize: Bool { foundSplit && allSucceeded }
    }
}
