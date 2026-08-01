public import Foundation

/// Describes deterministic inputs consumed by the pure Fleet supervisor.
///
/// Signals about a specific agent run carry the attempt that produced them; the reducer drops mismatches.
public enum FleetSignal: Equatable, Codable, Sendable {
    /// A work source produced a fresh normalized task list.
    case sourceSync(tasks: [FleetTask], at: Date)

    /// The scheduler dispatched a queued task for workspace provisioning.
    case dispatched(taskID: FleetTaskID, at: Date)

    /// Workspace provisioning succeeded for a task.
    case provisioned(taskID: FleetTaskID, path: String, isBrandNew: Bool, at: Date)

    /// Workspace provisioning failed for a task.
    case provisionFailed(taskID: FleetTaskID, message: String, at: Date)

    /// An agent session started for a specific task attempt.
    case agentSessionStarted(taskID: FleetTaskID, attempt: Int, sessionID: String, pid: Int32?, at: Date)

    /// Fleet observed activity for a specific task attempt.
    case activity(taskID: FleetTaskID, attempt: Int, at: Date)

    /// The agent requested human input for a specific task attempt.
    case blockingItemReceived(taskID: FleetTaskID, attempt: Int, at: Date)

    /// The human-input blocker for a specific task attempt was resolved.
    case blockingItemResolved(taskID: FleetTaskID, attempt: Int, at: Date)

    /// The agent stopped and emitted its normal stop signal for a specific task attempt.
    case agentStopped(taskID: FleetTaskID, attempt: Int, at: Date)

    /// The agent process exited without a normal stop signal for a specific task attempt.
    case pidExited(taskID: FleetTaskID, attempt: Int, at: Date)

    /// The terminal returned to an idle prompt while a specific attempt was expected to be running.
    case promptIdleObserved(taskID: FleetTaskID, attempt: Int, at: Date)

    /// Fleet's stall timeout elapsed for a specific task attempt.
    case stallTimeout(taskID: FleetTaskID, attempt: Int, at: Date)

    /// A scheduled retry backoff elapsed for a specific task attempt.
    case backoffElapsed(taskID: FleetTaskID, attempt: Int, at: Date)

    /// The workspace attached to a task was closed.
    case workspaceClosed(taskID: FleetTaskID, at: Date)

    /// The pull request snapshot changed for a task.
    case prChanged(taskID: FleetTaskID, pr: FleetPullRequestStatus, at: Date)

    /// The source reported that a task reached a terminal state.
    case sourceReachedTerminalState(taskID: FleetTaskID, at: Date)

    /// The user requested a retry for a task.
    case userRetry(taskID: FleetTaskID, at: Date)

    /// The user cancelled a task.
    case userCancel(taskID: FleetTaskID, at: Date)
}
