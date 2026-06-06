import Foundation

struct ClosedPanelHistoryEntry: Codable {
    let workspaceId: UUID
    let paneId: UUID
    let paneAnchorPanelId: UUID?
    let restoreInOriginalPane: Bool
    let tabIndex: Int
    let snapshot: SessionPanelSnapshot
    let fallbackSplitPlacement: ClosedPanelSplitPlacement?

    init(
        workspaceId: UUID,
        paneId: UUID,
        paneAnchorPanelId: UUID? = nil,
        restoreInOriginalPane: Bool = true,
        tabIndex: Int,
        snapshot: SessionPanelSnapshot,
        fallbackSplitPlacement: ClosedPanelSplitPlacement? = nil
    ) {
        self.workspaceId = workspaceId
        self.paneId = paneId
        self.paneAnchorPanelId = paneAnchorPanelId
        self.restoreInOriginalPane = restoreInOriginalPane
        self.tabIndex = tabIndex
        self.snapshot = snapshot
        self.fallbackSplitPlacement = fallbackSplitPlacement
    }
}
