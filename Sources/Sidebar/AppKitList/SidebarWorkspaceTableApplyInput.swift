import Foundation

/// The latest immutable input delivered by the SwiftUI table bridge.
@MainActor
struct SidebarWorkspaceTableApplyInput {
    let rows: [SidebarWorkspaceTableRowConfiguration]
    let actions: SidebarWorkspaceTableActions
    let workspaceIds: [UUID]
    let selectedWorkspaceId: UUID?
    let selectedScrollTargetWorkspaceId: UUID?
    let rowSpacing: CGFloat

    init(
        rows: [SidebarWorkspaceTableRowConfiguration],
        actions: SidebarWorkspaceTableActions,
        workspaceIds: [UUID],
        selectedWorkspaceId: UUID?,
        selectedScrollTargetWorkspaceId: UUID?,
        rowSpacing: CGFloat = 1
    ) {
        self.rows = rows
        self.actions = actions
        self.workspaceIds = workspaceIds
        self.selectedWorkspaceId = selectedWorkspaceId
        self.selectedScrollTargetWorkspaceId = selectedScrollTargetWorkspaceId
        self.rowSpacing = rowSpacing
    }
}
