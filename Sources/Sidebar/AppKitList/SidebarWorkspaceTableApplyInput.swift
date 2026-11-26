import Foundation

/// The latest immutable input delivered by the SwiftUI table bridge.
@MainActor
struct SidebarWorkspaceTableApplyInput {
    let rows: [SidebarWorkspaceTableRowConfiguration]
    let actions: SidebarWorkspaceTableActions
    let workspaceIds: [UUID]
    let selectedWorkspaceId: UUID?
    let selectedScrollTargetWorkspaceId: UUID?
    /// Restores the mounted table's viewport after a hidden-presentation pass
    /// mutated the controller snapshot and requires an authoritative reload.
    let forcedReloadViewportOrigin: CGPoint?

    /// Whether this input must reconcile a table graph pruned while hidden.
    var forceTableReload: Bool { forcedReloadViewportOrigin != nil }

    init(
        rows: [SidebarWorkspaceTableRowConfiguration],
        actions: SidebarWorkspaceTableActions,
        workspaceIds: [UUID],
        selectedWorkspaceId: UUID?,
        selectedScrollTargetWorkspaceId: UUID?,
        forcedReloadViewportOrigin: CGPoint? = nil
    ) {
        self.rows = rows
        self.actions = actions
        self.workspaceIds = workspaceIds
        self.selectedWorkspaceId = selectedWorkspaceId
        self.selectedScrollTargetWorkspaceId = selectedScrollTargetWorkspaceId
        self.forcedReloadViewportOrigin = forcedReloadViewportOrigin
    }
}
