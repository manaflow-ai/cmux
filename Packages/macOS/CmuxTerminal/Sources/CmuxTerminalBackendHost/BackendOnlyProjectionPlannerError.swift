internal import CmuxTerminalBackend

/// A fail-closed mismatch between canonical topology and navigation state.
nonisolated enum BackendOnlyProjectionPlannerError: Error, Equatable, Sendable {
    case selectedWorkspaceRequired
    case selectedWorkspaceMissing(WorkspaceID)
    case navigationWorkspaceMissing(WorkspaceID)
    case duplicateNavigationWorkspace(WorkspaceID)
    case selectedScreenMissing(workspaceID: WorkspaceID, screenID: ScreenID)
    case navigationScreenMissing(workspaceID: WorkspaceID, screenID: ScreenID)
    case duplicateNavigationScreen(ScreenID)
    case activePaneMissing(screenID: ScreenID, paneID: PaneID)
    case zoomedPaneMustBeActive(screenID: ScreenID, activePaneID: PaneID, zoomedPaneID: PaneID)
    case navigationPaneMissing(PaneID)
    case navigationPaneOutsideSelectedScreen(screenID: ScreenID, paneID: PaneID)
    case duplicateNavigationPane(PaneID)
    case selectedSurfaceMissing(paneID: PaneID, surfaceID: SurfaceID)
    case layoutPaneIdentityMismatch(numericPaneID: UInt64, paneID: PaneID)
    case layoutDepthExceeded(actual: Int, maximum: Int)
    case visibleLeafLimitExceeded(actual: Int, maximum: Int)
}
