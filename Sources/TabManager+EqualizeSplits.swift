import CmuxPanes
import Foundation

extension TabManager {
    /// Equalize splits - not directly supported by bonsplit.
    func equalizeSplits(tabId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        if tab.panels.values.contains(where: { $0 is TerminalPanel }),
           let mutationCoordinator = terminalClientComposition.terminalBackendTopologyMutationCoordinator,
           !tab.isApplyingCanonicalTopologyProjection {
            return mutationCoordinator.reject(.changeSplitRatio)
        }

        let result = equalizeSplitsOnce(in: tab)
        if result.foundSplit {
            tab.didProgrammaticallyChangeSplitGeometry()
        }
        return result.didFullyEqualize
    }

    @discardableResult
    private func equalizeSplitsOnce(in tab: Workspace) -> SplitEqualizeResult {
        paneLayout.equalizeSplits(
            in: tab.bonsplitController.treeSnapshot(),
            controller: tab.bonsplitController
        )
    }
}
