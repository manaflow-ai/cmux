import Foundation

/// Mutable per-pane evidence and action state owned by ``AgentStallSupervisor``.
@MainActor
struct AgentStallSupervisorPanelState {
    enum Phase: Equatable {
        case idle
        case running
        case retryWaiting
        case retrying
        case humanRequired
        case exhausted

        var hasVisibleStatus: Bool {
            switch self {
            case .retryWaiting, .humanRequired, .exhausted:
                true
            case .idle, .running, .retrying:
                false
            }
        }
    }

    /// Whether an authoritative boundary may still refine this generation.
    enum BoundaryCommitment: Equatable {
        /// No policy decision has consumed the boundary.
        case open
        /// A generic completion hint won; structured failure may still supersede it.
        case normalCompletion
        /// A retry, notification, exhaustion state, or fail-closed rejection is final.
        case actionCommitted
    }

    /// Prompt-boundary evidence retained until process identity is authoritative.
    ///
    /// The PID and lifecycle commands travel through separate mutation-bus
    /// entries. Keeping the capture here prevents an idle hook that drains first
    /// from losing a proven banner while still failing closed when identity never
    /// becomes available.
    struct PendingBoundary {
        let generation: UInt64
        let normalCompletion: Bool
        let hasStructuredEvidence: Bool
        let outputCapture: AgentStallOutputCapture?
    }

    var generation: UInt64 = 0
    var lifecycle: AgentHibernationLifecycleState = .unknown
    var binding: SurfaceResumeBindingSnapshot?
    var processID: pid_t?
    var processIdentity: AgentPIDProcessIdentity?
    var ownerToken: String?
    var retryAttempts = 0
    var phase: Phase = .idle
    var boundaryCommitment: BoundaryCommitment = .open
    var pendingBoundary: PendingBoundary?
    var retryToken: UUID?
    var retryTimer: Timer?
}
