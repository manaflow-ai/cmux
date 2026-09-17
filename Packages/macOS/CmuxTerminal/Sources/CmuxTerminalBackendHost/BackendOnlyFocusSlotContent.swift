internal import CmuxTerminalBackend

/// Visible pane materialization relevant to terminal first-responder policy.
nonisolated enum BackendOnlyFocusSlotContent: Equatable, Sendable {
    case terminal(selectedSurfaceID: SurfaceID)
    case browserPlaceholder(selectedSurfaceID: SurfaceID)
    case unsupportedPlaceholder(selectedSurfaceID: SurfaceID)

    var selectedSurfaceID: SurfaceID {
        switch self {
        case let .terminal(selectedSurfaceID),
             let .browserPlaceholder(selectedSurfaceID),
             let .unsupportedPlaceholder(selectedSurfaceID):
            selectedSurfaceID
        }
    }

    var isTerminal: Bool {
        if case .terminal = self {
            true
        } else {
            false
        }
    }

    func selecting(_ surfaceID: SurfaceID) -> BackendOnlyFocusSlotContent {
        switch self {
        case .terminal:
            .terminal(selectedSurfaceID: surfaceID)
        case .browserPlaceholder:
            .browserPlaceholder(selectedSurfaceID: surfaceID)
        case .unsupportedPlaceholder:
            .unsupportedPlaceholder(selectedSurfaceID: surfaceID)
        }
    }
}
