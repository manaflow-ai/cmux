import Bonsplit
import Foundation

extension TabManager {
    /// Equalize splits - not directly supported by bonsplit.
    func equalizeSplits(tabId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }

        let controller = tab.focusedBonsplitControllerForCommands()
        let result = equalizeSplitsOnce(in: tab, controller: controller)
        if result.foundSplit {
            tab.didProgrammaticallyChangeSplitGeometry()
            scheduleEqualizeSplitsFollowUp(tabId: tabId, controller: controller)
        }
        return result.didFullyEqualize
    }

    @discardableResult
    private func equalizeSplitsOnce(
        in tab: Workspace,
        controller: BonsplitController
    ) -> TerminalController.EqualizeSplitsResult {
        TerminalController.equalizeSplitsProportionally(
            in: controller.treeSnapshot(),
            controller: controller,
            fromExternal: true
        )
    }

    private func scheduleEqualizeSplitsFollowUp(tabId: UUID, controller: BonsplitController) {
        DispatchQueue.main.async { [weak self] in
            self?.runEqualizeSplitsFollowUp(tabId: tabId, controller: controller)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.runEqualizeSplitsFollowUp(tabId: tabId, controller: controller)
        }
    }

    private func runEqualizeSplitsFollowUp(tabId: UUID, controller: BonsplitController) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        if equalizeSplitsOnce(in: tab, controller: controller).foundSplit {
            tab.didProgrammaticallyChangeSplitGeometry()
        }
    }

}
