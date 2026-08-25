import Foundation

/// The latest immutable input delivered by the SwiftUI table bridge.
@MainActor
struct SidebarWorkspaceTableApplyInput {
    let rows: [SidebarWorkspaceTableRowConfiguration]
    let actions: SidebarWorkspaceTableActions
    let workspaceIds: [UUID]
    let selectedWorkspaceId: UUID?
    let selectedScrollTargetWorkspaceId: UUID?
    /// Requests a reload after a hidden-presentation pass already mutated the
    /// controller's row snapshot before this authoritative input arrived.
    let forceTableReload: Bool

    init(
        rows: [SidebarWorkspaceTableRowConfiguration],
        actions: SidebarWorkspaceTableActions,
        workspaceIds: [UUID],
        selectedWorkspaceId: UUID?,
        selectedScrollTargetWorkspaceId: UUID?,
        forceTableReload: Bool = false
    ) {
        self.rows = rows
        self.actions = actions
        self.workspaceIds = workspaceIds
        self.selectedWorkspaceId = selectedWorkspaceId
        self.selectedScrollTargetWorkspaceId = selectedScrollTargetWorkspaceId
        self.forceTableReload = forceTableReload
    }
}
