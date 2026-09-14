import CmuxCore

/// Transport state consumed by the pane's presentation owner.
struct CloudManualMirrorPresentation {
    let phase: CloudTuiManualMirrorPhase
    let replayReceived: Bool
    let rendererReady: Bool

    var connectionState: WorkspaceRemoteConnectionState? {
        switch phase {
        case .idle: return nil
        case .connecting: return .connecting
        case .attached: return replayReceived && rendererReady ? .connected : .connecting
        case .disconnected: return .error
        case .stopped: return nil
        }
    }
}
