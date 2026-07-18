import Foundation

/// Latest immutable sidebar projection waiting to cross into the AppKit table.
@MainActor
struct SidebarWorkspaceTableApplyInput {
    let rows: [SidebarWorkspaceTableRowConfiguration]
    let actions: SidebarWorkspaceTableActions
    let workspaceIds: [UUID]
    let selectedWorkspaceId: UUID?
    let selectedScrollTargetWorkspaceId: UUID?
    let isDividerDragActive: Bool
}
