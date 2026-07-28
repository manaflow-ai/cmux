import Foundation

/// Per-pane retry budget and timer state retained across one managed session.
struct AgentSessionRetryPanelState {
    enum Phase: Equatable {
        case waiting(attempt: Int, maximumAttempts: Int, exitCode: Int)
        case launching(attempt: Int, maximumAttempts: Int)
        case exhausted(maximumAttempts: Int)

        var isWaitingOrExhausted: Bool {
            switch self {
            case .waiting, .exhausted:
                true
            case .launching:
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
