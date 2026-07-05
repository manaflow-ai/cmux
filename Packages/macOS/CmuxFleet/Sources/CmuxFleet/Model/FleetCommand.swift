/// Describes a pure Fleet supervisor effect for an imperative engine to perform.
public enum FleetCommand: Equatable, Codable, Sendable {
    /// Create or attach a workspace for a queued task.
    case provisionWorkspace(task: FleetTask)

    /// Launch the agent for a task attempt.
    case launchAgent(task: FleetTask, attempt: Int)

    /// Re-send the agent command after retry backoff elapses.
    case resendAgentCommand(task: FleetTask, attempt: Int)

    /// Kill the currently supervised agent for a task.
    case killAgent(task: FleetTask)

    /// Schedule a retry backoff timer for a task.
    case scheduleBackoff(taskID: FleetTaskID, delayMS: Int)

    /// Cancel a retry backoff timer for a task.
    case cancelBackoff(taskID: FleetTaskID)

    /// Post a Fleet notification for a task.
    case postNotification(taskID: FleetTaskID, kind: FleetNotificationKind)

    /// Clean up the workspace attached to a completed task.
    case cleanupWorkspace(task: FleetTask)

    /// Persist the current Fleet snapshot.
    case persistSnapshot

    /// Represents an explicit no-op command.
    case none
}
