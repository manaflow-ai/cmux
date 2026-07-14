import CmuxAgentGUIProjection
import CmuxAgentSync

enum TranscriptSyncPresentation: Equatable {
    case hidden
    case empty
    case loading
    case error
    case stale

    init(
        phase: AgentConnectivityPhase,
        consecutiveFailures: Int,
        input: TranscriptProjectionInput
    ) {
        let hasContent = input.hasVisibleContent
        if consecutiveFailures >= 2 {
            self = hasContent ? .stale : .error
        } else if !hasContent, phase != .connected {
            self = .loading
        } else if !hasContent, input.hasCompletedInitialSync {
            self = .empty
        } else {
            self = .hidden
        }
    }
}
