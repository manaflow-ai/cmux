public import Foundation

/// One drawable item in the workspace sidebar.
@MainActor
public enum SidebarWorkspaceRenderItem<Tab: WorkspaceTabRepresenting> {
    /// A workspace group header row and the workspace ids contained by that group.
    case groupHeader(WorkspaceGroup, memberWorkspaceIds: [UUID])
    /// A visible workspace row.
    case workspace(Tab)

    /// Stable identity for SwiftUI row diffing.
    public var id: SidebarWorkspaceRenderItemID {
        switch self {
        case .groupHeader(let group, _):
            return SidebarWorkspaceRenderItemID(groupId: group.id)
        case .workspace(let workspace):
            return SidebarWorkspaceRenderItemID(workspaceId: workspace.id)
        }
    }

    /// The workspace id represented by this visible row.
    public var rowWorkspaceId: UUID {
        switch self {
        case .groupHeader(let group, _):
            return group.anchorWorkspaceId
        case .workspace(let workspace):
            return workspace.id
        }
    }

}
