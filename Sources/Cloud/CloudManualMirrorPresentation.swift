import CmuxCore

/// Transport state consumed by the pane's presentation owner.
struct CloudManualMirrorPresentation {
    let phase: CloudTuiManualMirrorPhase
    let replayReceived: Bool
    var firstFramePresented: Bool = false

    var connectionState: WorkspaceRemoteConnectionState? {
        switch phase {
        case .idle, .connecting: return .connecting
        case .attached: return replayReceived && firstFramePresented ? .connected : .connecting
        case .disconnected: return .error
        case .stopped: return nil
        }
    }
}
