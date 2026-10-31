import Foundation

/// Where a tab dragged in from a pane would land on the sidebar.
public nonisolated enum SidebarTabDrop: Hashable, Sendable {
    /// Move the tab into an existing workspace.
    case intoWorkspace(WorkspaceID)
    /// Create a workspace at a sidebar insertion slot.
    case newWorkspace(section: SectionID, group: GroupID?, index: Int)
    /// Create a workspace at the end of a collapsed group.
    case intoGroup(GroupID)
}
