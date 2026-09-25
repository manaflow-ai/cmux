import CmuxCloud

extension CmuxTuiSurfaceProvider.ProviderError: CloudDiagnosticFailureClassifying {
    var cloudDiagnosticFailure: CloudDiagnosticFailure {
        switch self {
        case .notSignedIn: return .authentication
        case .machineAsleep, .remoteWorkspaceNotFound, .remoteTabNotFound: return .notFound
        case .noWorkspaceOnMachine, .remotePlacementUnavailable: return .placement
        case .terminalNotCreated, .terminalExited: return .process
        case .terminalAttachTimedOut: return .timeout
        case .invalidSnapshot, .stateUnavailable: return .response
        case .snapshotOnly, .hubUnavailable: return .unsupported
        case .invalidPreviewURL, .localForwardURLUnavailable: return .response
        }
    }
}
