import Foundation

extension ClosedItemHistoryStore {
    /// Replaces one still-present close record while preserving its stable ID,
    /// timestamp, and ordering. Removal plus reinsertion is synchronous on the
    /// main actor; revision ordering prevents an intermediate save from winning.
    @discardableResult
    func enrichClosedPanelAgent(recordId: UUID, agent: SessionRestorableAgentSnapshot) -> Bool {
        guard let removed = removeRecord(id: recordId) else { return false }
        guard case .panel(let panelEntry) = removed.record.entry,
              panelEntry.snapshot.terminal?.agent == nil else {
            insert(removed.record, at: removed.index)
            return false
        }
        var snapshot = panelEntry.snapshot
        snapshot.terminal?.agent = agent
        let enriched = ClosedPanelHistoryEntry(
            workspaceId: panelEntry.workspaceId,
            paneId: panelEntry.paneId,
            paneAnchorPanelId: panelEntry.paneAnchorPanelId,
            restoreInOriginalPane: panelEntry.restoreInOriginalPane,
            tabIndex: panelEntry.tabIndex,
            snapshot: snapshot,
            fallbackSplitPlacement: panelEntry.fallbackSplitPlacement
        )
        insert(ClosedItemHistoryRecord(
            id: removed.record.id,
            closedAt: removed.record.closedAt,
            entry: .panel(enriched)
        ), at: removed.index)
        return true
    }
}
