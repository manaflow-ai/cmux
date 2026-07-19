internal import CmuxTerminalBackend
internal import Foundation

/// The minimal projection-navigation v2 value consumed by the pure planner.
nonisolated struct BackendOnlyProjectionNavigationInput: Equatable, Sendable {
    let logicalPresentationID: UUID
    let selectedWorkspaceID: WorkspaceID?
    let workspaces: [BackendOnlyProjectionWorkspaceNavigation]
}

nonisolated extension BackendOnlyProjectionNavigationInput {
    init(_ state: BackendProjectionNavigationState) {
        self.init(
            logicalPresentationID: state.logicalPresentationID,
            selectedWorkspaceID: state.selectedWorkspaceID,
            workspaces: state.workspaces.map { workspace in
                BackendOnlyProjectionWorkspaceNavigation(
                    workspaceID: workspace.workspaceID,
                    selectedScreenID: workspace.selectedScreenID,
                    screens: workspace.screens.map { screen in
                        BackendOnlyProjectionScreenNavigation(
                            screenID: screen.screenID,
                            activePaneID: screen.activePaneID,
                            zoomedPaneID: screen.zoomedPaneID,
                            panes: screen.panes.map { pane in
                                BackendOnlyProjectionPaneNavigation(
                                    paneID: pane.paneID,
                                    selectedSurfaceID: pane.selectedSurfaceID
                                )
                            }
                        )
                    }
                )
            }
        )
    }
}
