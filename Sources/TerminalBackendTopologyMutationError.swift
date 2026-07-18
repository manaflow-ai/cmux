import CmuxTerminalBackend

/// Fail-closed validation errors raised before a topology command reaches cmuxd.
enum TerminalBackendTopologyMutationError: Error, Equatable, Sendable {
    case canonicalSnapshotUnavailable
    case authorityChanged(expected: BackendAuthority, actual: BackendAuthority)
    case workspaceNotFound(WorkspaceID)
    case paneNotFound(PaneID)
    case surfaceNotFound(SurfaceID)
    case invalidIndex(Int)
    case invalidSplitRatio(Float)
}
