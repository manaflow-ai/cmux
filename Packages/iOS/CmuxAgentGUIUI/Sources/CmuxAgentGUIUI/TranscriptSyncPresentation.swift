import CmuxAgentSync

enum TranscriptSyncPresentation: Equatable {
    case hidden
    case loading
    case error
    case stale

    init(phase: AgentConnectivityPhase, consecutiveFailures: Int, hasContent: Bool) {
        if consecutiveFailures >= 2 {
            self = hasContent ? .stale : .error
        } else if !hasContent, phase != .connected {
            self = .loading
        } else {
            self = .hidden
        }
    }
}
