import Foundation

/// Parent-owned immutable values consumed by the workspace sidebar's lazy rows.
///
/// Group rows and shared menu facts are value projections built before
/// `LazyVStack`. Workspace inputs are resolved lazily from copied values, never
/// from observable stores.
struct SidebarWorkspaceRowsSnapshot {
    let groupRowsById: [UUID: SidebarWorkspaceGroupRowSnapshot]
    let workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot
    let canCreateEmptyGroup: Bool
    let selectedContextMenuTargetAggregate: SidebarWorkspaceContextMenuTargetAggregate

    private let anchorWorkspaceIds: Set<UUID>
    private let modelSnapshotsById: [UUID: SidebarWorkspaceRowModelSnapshot]
    private let unreadSummariesByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary]

    init(
        modelSnapshotsById: [UUID: SidebarWorkspaceRowModelSnapshot],
        groupRowsById: [UUID: SidebarWorkspaceGroupRowSnapshot],
        selectedContextTargetIds: [UUID],
        anchorWorkspaceIds: Set<UUID>,
        workspaceGroupMenuSnapshot: WorkspaceGroupMenuSnapshot,
        canCreateEmptyGroup: Bool,
        unreadSummariesByWorkspaceId: [UUID: SidebarWorkspaceUnreadSummary]
    ) {
        self.groupRowsById = groupRowsById
        self.workspaceGroupMenuSnapshot = workspaceGroupMenuSnapshot
        self.canCreateEmptyGroup = canCreateEmptyGroup
        self.anchorWorkspaceIds = anchorWorkspaceIds
        self.modelSnapshotsById = modelSnapshotsById
        self.unreadSummariesByWorkspaceId = unreadSummariesByWorkspaceId
        selectedContextMenuTargetAggregate = SidebarWorkspaceContextMenuTargetAggregate(
            targetWorkspaceIds: selectedContextTargetIds,
            modelSnapshotsById: modelSnapshotsById,
            unreadSummariesByWorkspaceId: unreadSummariesByWorkspaceId,
            anchorWorkspaceIds: anchorWorkspaceIds
        )
    }

    func contextMenuTargetAggregate(
        for input: SidebarWorkspaceRowInput
    ) -> SidebarWorkspaceContextMenuTargetAggregate {
        guard !input.isMultiSelected else {
            return selectedContextMenuTargetAggregate
        }
        return SidebarWorkspaceContextMenuTargetAggregate(
            targetWorkspaceIds: [input.workspaceId],
            modelSnapshotsById: modelSnapshotsById,
            unreadSummariesByWorkspaceId: unreadSummariesByWorkspaceId,
            anchorWorkspaceIds: anchorWorkspaceIds
        )
    }
}
