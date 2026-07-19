import Foundation

extension Workspace {
    /// Captures close history immediately, then fills a missing agent snapshot
    /// after the shared index's off-main cold load finishes.
    func pushClosedPanelHistoryEntryWithAgentEnrichment(_ entry: ClosedPanelHistoryEntry) {
        let recordId = ClosedItemHistoryStore.shared.push(.panel(entry))
        guard entry.snapshot.terminal?.agent == nil else { return }
        let workspaceId = entry.workspaceId
        let panelId = entry.snapshot.id
        // Root exit is recorded in memory before its queued disk write. Do not
        // let a cold index refresh reattach the stale pre-exit record after the
        // panel lifecycle cleanup removes this completion marker.
        guard Self.closedPanelAgentEnrichmentAllowed(
            resumeState: restoredAgentResumeStatesByPanelId[panelId]
        ) else { return }
        Task { @MainActor in
            guard let index = await SharedLiveAgentIndex.shared.currentIndexAfterRefreshing(),
                  let agent = index.snapshot(workspaceId: workspaceId, panelId: panelId) else {
                return
            }
            ClosedItemHistoryStore.shared.enrichClosedPanelAgent(recordId: recordId, agent: agent)
        }
    }

    static func closedPanelAgentEnrichmentAllowed(
        resumeState: RestoredAgentResumeState?
    ) -> Bool {
        resumeState != .completedAgentExit
    }
}
