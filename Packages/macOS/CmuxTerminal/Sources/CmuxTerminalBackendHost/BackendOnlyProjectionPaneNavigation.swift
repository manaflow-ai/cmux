internal import CmuxTerminalBackend

/// The daemon-selected surface for one pane in projection-navigation v2 state.
nonisolated struct BackendOnlyProjectionPaneNavigation: Equatable, Sendable {
    let paneID: PaneID
    let selectedSurfaceID: SurfaceID
}
