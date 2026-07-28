import Foundation

/// Per-pane retry budget and timer state retained across one managed session.
struct AgentSessionRetryPanelState {
    enum Phase: Equatable {
        case waiting(attempt: Int, maximumAttempts: Int, exitCode: Int)
        case ready(attempt: Int, maximumAttempts: Int)
        case awaitingLaunch(attempt: Int, maximumAttempts: Int)
        case running(attempt: Int, maximumAttempts: Int)
        case exhausted(maximumAttempts: Int)

        var isPendingOrExhausted: Bool {
            switch self {
            case .waiting, .ready, .awaitingLaunch, .exhausted:
                true
            case .running:
                false
            }
        }

        var isWaitingOrReadyOrExhausted: Bool {
            switch self {
            case .waiting, .ready, .exhausted:
                true
            case .awaitingLaunch, .running:
                false
            }
        }
    }

    var completedAttempts: Int
    var binding: SurfaceResumeBindingSnapshot
    var commandGeneration: UInt64
    var phase: Phase
    var timer: Timer?
}
