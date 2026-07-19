import Foundation

extension TabManager {
    /// Captures workspace history immediately, then fills missing terminal
    /// agent snapshots after the shared index's off-main cold load finishes.
    func pushClosedWorkspaceHistoryEntryWithAgentEnrichment(
        _ entry: ClosedWorkspaceHistoryEntry,
        excludedPanelIds: Set<UUID> = []
    ) {
        let recordId = ClosedItemHistoryStore.shared.push(.workspace(entry))
        let missingPanelIds = entry.snapshot.panels.compactMap { panel in
            panel.terminal?.agent == nil && !excludedPanelIds.contains(panel.id) ? panel.id : nil
        }
        guard !missingPanelIds.isEmpty else { return }
        let workspaceId = entry.workspaceId
        Task { @MainActor in
            guard let index = await SharedLiveAgentIndex.shared.currentIndexAfterRefreshing() else { return }
            let agents = Dictionary(uniqueKeysWithValues: missingPanelIds.compactMap { panelId in
                index.snapshot(workspaceId: workspaceId, panelId: panelId).map { (panelId, $0) }
            })
            ClosedItemHistoryStore.shared.enrichClosedWorkspaceAgents(
                recordId: recordId,
                agentsByPanelId: agents
            )
        }
    }
}
