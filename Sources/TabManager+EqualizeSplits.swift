import Bonsplit
import Foundation

extension TabManager {
    /// Equalize splits - not directly supported by bonsplit.
    func equalizeSplits(tabId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }

        let controller = tab.focusedBonsplitControllerForCommands()
        let result = equalizeSplitsOnce(controller: controller)
        if result.foundSplit {
            tab.didProgrammaticallyChangeSplitGeometry()
        }
        return result.didFullyEqualize
    }

    @discardableResult
    private func equalizeSplitsOnce(controller: BonsplitController) -> SplitEqualizer.Result {
        SplitEqualizer.equalize(
            in: controller.treeSnapshot(),
            controller: controller
        )
    }
}
