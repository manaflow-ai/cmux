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
    private func equalizeSplitsOnce(in tab: Workspace) -> SplitEqualizer.Result {
        SplitEqualizer.equalize(
            in: tab.bonsplitController.treeSnapshot(),
            controller: tab.bonsplitController
        )
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

}

@MainActor
enum SplitEqualizer {
    struct Result {
        let foundSplit: Bool
        let allSucceeded: Bool

        var didFullyEqualize: Bool { foundSplit && allSucceeded }
    }

    @discardableResult
    static func equalize(
        in node: ExternalTreeNode,
        controller: BonsplitController,
        orientationFilter: String? = nil
    ) -> Result {
        var foundSplit = false
        var allSucceeded = true
        _ = equalize(
            node,
            controller: controller,
            orientationFilter: orientationFilter,
            foundSplit: &foundSplit,
            allSucceeded: &allSucceeded
        )
        return Result(foundSplit: foundSplit, allSucceeded: allSucceeded)
    }

    @discardableResult
    private static func equalize(
        _ node: ExternalTreeNode,
        controller: BonsplitController,
        orientationFilter: String?,
        foundSplit: inout Bool,
        allSucceeded: inout Bool
    ) -> Int {
        switch node {
        case .pane:
            return 1
        case .split(let splitNode):
            let firstLeafCount = equalize(
                splitNode.first,
                controller: controller,
                orientationFilter: orientationFilter,
                foundSplit: &foundSplit,
                allSucceeded: &allSucceeded
            )
            let secondLeafCount = equalize(
                splitNode.second,
                controller: controller,
                orientationFilter: orientationFilter,
                foundSplit: &foundSplit,
                allSucceeded: &allSucceeded
            )

            if orientationFilter == nil || splitNode.orientation == orientationFilter {
                foundSplit = true
                if let splitId = UUID(uuidString: splitNode.id) {
                    let totalLeafCount = firstLeafCount + secondLeafCount
                    let position = CGFloat(firstLeafCount) / CGFloat(totalLeafCount)
                    if !controller.setDividerPosition(position, forSplit: splitId, fromExternal: true) {
                        allSucceeded = false
                    }
                } else {
                    allSucceeded = false
                }
            }

            return firstLeafCount + secondLeafCount
        }
    }
}
