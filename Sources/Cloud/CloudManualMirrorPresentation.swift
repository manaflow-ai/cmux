import CmuxCore

/// Transport state consumed by the pane's presentation owner.
struct CloudManualMirrorPresentation {
    let phase: CloudTuiManualMirrorPhase
    let replayReceived: Bool
    let rendererReady: Bool
    let surfaceResolutionPending: Bool

    init(
        phase: CloudTuiManualMirrorPhase,
        replayReceived: Bool,
        rendererReady: Bool,
        surfaceResolutionPending: Bool = false
    ) {
        self.phase = phase
        self.replayReceived = replayReceived
        self.rendererReady = rendererReady
        self.surfaceResolutionPending = surfaceResolutionPending
    }

    var connectionState: WorkspaceRemoteConnectionState? {
        switch phase {
        case .idle: return surfaceResolutionPending ? .connecting : nil
        case .connecting: return .connecting
        case .attached: return replayReceived && rendererReady ? .connected : .connecting
        case .disconnected: return .error
        case .stopped: return nil
        }
    }
}
