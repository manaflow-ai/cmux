import Foundation

/// The latest immutable input delivered to the AppKit table.
@MainActor
struct SidebarWorkspaceTableApplyInput {
    let rows: [SidebarWorkspaceTableRowConfiguration]
    let actions: SidebarWorkspaceTableActions
    let workspaceIds: [UUID]
    let selectedWorkspaceId: UUID?
    let selectedScrollTargetWorkspaceId: UUID?
}
