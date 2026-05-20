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
    private func equalizeSplitsOnce(in tab: Workspace) -> TerminalController.EqualizeSplitsResult {
        TerminalController.equalizeSplitsProportionally(
            in: tab.bonsplitController.treeSnapshot(),
            controller: tab.bonsplitController,
            fromExternal: true
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
