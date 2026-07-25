import CmuxAgentGUIProjection
import CmuxAgentSync

enum TranscriptSyncPresentation: Equatable {
    case hidden
    case empty
    case loading
    case error
    case stale

    var showsPlaceholderRow: Bool {
        switch self {
        case .empty, .loading, .error:
            true
        case .hidden, .stale:
            false
        }
    }

    init(
        phase: AgentConnectivityPhase,
        consecutiveFailures: Int,
        input: TranscriptProjectionInput
    ) {
        self.init(
            phase: phase,
            consecutiveFailures: consecutiveFailures,
            hasVisibleContent: input.hasVisibleContent,
            hasCompletedInitialSync: input.hasCompletedInitialSync,
            hasMoreAfter: input.hasMoreAfter
        )
    }

    init(
        phase: AgentConnectivityPhase,
        consecutiveFailures: Int,
        hasVisibleContent: Bool,
        hasCompletedInitialSync: Bool,
        hasMoreAfter: Bool
    ) {
        if consecutiveFailures >= 2 {
            self = hasVisibleContent ? .stale : .error
        } else if !hasVisibleContent, phase != .connected {
            self = .loading
        } else if !hasVisibleContent, hasMoreAfter {
            self = .loading
        } else if !hasVisibleContent, hasCompletedInitialSync {
            self = .empty
        } else {
            self = .hidden
        }
    }
}
