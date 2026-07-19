internal import CmuxTerminalBackend

/// The daemon-selected pane, zoom, and tabs for one screen.
nonisolated struct BackendOnlyProjectionScreenNavigation: Equatable, Sendable {
    let screenID: ScreenID
    let activePaneID: PaneID
    let zoomedPaneID: PaneID?
    let panes: [BackendOnlyProjectionPaneNavigation]
}
