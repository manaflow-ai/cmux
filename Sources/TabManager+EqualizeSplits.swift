import CMUXLayout
import Foundation

extension TabManager {
    /// Equalize splits - not directly supported by workspaceLayout.
    func equalizeSplits(tabId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }

        let result = equalizeSplitsOnce(in: tab)
        if result.foundSplit {
            tab.didProgrammaticallyChangeSplitGeometry()
        }
        return result.didFullyEqualize
    }

    @discardableResult
    private func equalizeSplitsOnce(in tab: Workspace) -> SplitEqualizer.Result {
        SplitEqualizer.equalize(
            in: tab.layoutController.treeSnapshot(),
            controller: tab.layoutController
        )
    }
}
