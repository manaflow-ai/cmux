/// Describes Fleet's normalized task state machine.
public enum FleetTaskState: String, CaseIterable, Codable, Sendable {
    /// The task is waiting for scheduler dispatch.
    case queued

    /// Fleet is creating or attaching a workspace for the task.
    case provisioning

    /// Fleet is launching or relaunching the agent command.
    case launching

    /// The agent is running without a known blocker.
    case running

    /// The agent has requested human input.
    case needsInput

    /// Fleet has observed no progress and is preparing recovery.
    case stalled

    /// Fleet is waiting before retrying the task.
    case retryBackoff

    /// A pull request exists and the task is waiting for human review.
    case awaitingReview

    /// The task reached a successful terminal state.
    case done

    /// Fleet exhausted retries or hit a non-recoverable failure.
    case failed

    /// The task was cancelled by the user, source, or workspace lifecycle.
    case cancelled

    /// Indicates whether no further automatic supervision should occur.
    public var isTerminal: Bool {
        switch self {
        case .done, .failed, .cancelled:
            true
        case .queued, .provisioning, .launching, .running, .needsInput, .stalled,
             .retryBackoff, .awaitingReview:
            false
        }
    }

    /// Indicates whether the task is in Fleet's active supervision loop.
    public var isActive: Bool {
        switch self {
        case .provisioning, .launching, .running, .needsInput, .stalled, .retryBackoff:
            true
        case .queued, .awaitingReview, .done, .failed, .cancelled:
            false
        }
    }

    /// Returns whether Fleet permits a task state transition.
    /// - Parameters:
    ///   - from: The current task state.
    ///   - to: The proposed next task state.
    /// - Returns: `true` when the transition is legal for the pure supervisor.
    public static func canTransition(from: FleetTaskState, to: FleetTaskState) -> Bool {
        if from == to {
            return true
        }

        return switch from {
        case .queued:
            to == .provisioning || to == .cancelled
        case .provisioning:
            to == .launching || to == .failed || to == .cancelled
        case .launching:
            to == .running || to == .retryBackoff || to == .awaitingReview || to == .done
                || to == .failed || to == .cancelled
        case .running:
            to == .needsInput || to == .retryBackoff || to == .awaitingReview || to == .done
                || to == .failed || to == .cancelled
        case .needsInput:
            to == .running || to == .retryBackoff || to == .awaitingReview || to == .done
                || to == .failed || to == .cancelled
        case .stalled:
            to == .retryBackoff || to == .done || to == .failed || to == .cancelled
        case .retryBackoff:
            to == .launching || to == .awaitingReview || to == .done || to == .cancelled
        case .awaitingReview:
            to == .done || to == .queued || to == .cancelled
        case .done:
            false
        case .failed:
            to == .awaitingReview || to == .done || to == .queued
        case .cancelled:
            to == .queued
        }
    }
}
