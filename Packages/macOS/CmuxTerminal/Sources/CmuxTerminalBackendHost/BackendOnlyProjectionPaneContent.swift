internal import CmuxTerminalBackend

/// The exact selected surface materialization for a visible pane.
nonisolated enum BackendOnlyProjectionPaneContent: Equatable, Sendable {
    case terminal(BackendOnlyTerminalSelection)
    case browserPlaceholder(
        surfaceID: SurfaceID,
        numericSurfaceID: UInt64,
        endpoint: CanonicalBrowserEndpoint?
    )
    case unsupportedPlaceholder(
        surfaceID: SurfaceID,
        numericSurfaceID: UInt64,
        kind: String
    )
}
