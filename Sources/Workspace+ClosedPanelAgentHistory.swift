import Foundation

extension Workspace {
    /// Captures close history immediately, then fills a missing agent snapshot
    /// after the shared index's off-main cold load finishes.
    func pushClosedPanelHistoryEntryWithAgentEnrichment(_ entry: ClosedPanelHistoryEntry) {
        let recordId = ClosedItemHistoryStore.shared.push(.panel(entry))
        guard entry.snapshot.terminal?.agent == nil else { return }
        let workspaceId = entry.workspaceId
        let panelId = entry.snapshot.id
        Task { @MainActor in
            guard let index = await SharedLiveAgentIndex.shared.currentIndexAfterRefreshing(),
                  let agent = index.snapshot(workspaceId: workspaceId, panelId: panelId) else {
                return
            }
            ClosedItemHistoryStore.shared.enrichClosedPanelAgent(recordId: recordId, agent: agent)
        }
    }
}
