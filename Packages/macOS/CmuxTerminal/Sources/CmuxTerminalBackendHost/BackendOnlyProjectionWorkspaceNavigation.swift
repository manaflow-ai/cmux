internal import CmuxTerminalBackend

/// The daemon-selected screen and screen preferences for one workspace.
nonisolated struct BackendOnlyProjectionWorkspaceNavigation: Equatable, Sendable {
    let workspaceID: WorkspaceID
    let selectedScreenID: ScreenID
    let screens: [BackendOnlyProjectionScreenNavigation]
}
