internal import CmuxTerminalBackend

enum BackendOnlyHostProjectionIntentKey: Hashable {
    case workspaceBinding(WorkspaceID)
    case selectedWorkspace
    case selectedScreen(WorkspaceID)
    case activePane(WorkspaceID, ScreenID)
    case zoomedPane(WorkspaceID, ScreenID)
    case selectedSurface(WorkspaceID, ScreenID, PaneID)
}
