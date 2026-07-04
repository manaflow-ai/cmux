import CmuxWorkspaces

@MainActor
enum SidebarWorkspaceRenderChildRow {
    case group(WorkspaceGroup)
    case workspace(Workspace)
}
