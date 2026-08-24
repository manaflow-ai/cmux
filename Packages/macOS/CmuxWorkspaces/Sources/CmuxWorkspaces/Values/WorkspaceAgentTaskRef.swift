import Foundation

/// Identifies the agent task mirrored by a workspace checklist row.
public struct WorkspaceAgentTaskRef: Codable, Sendable, Hashable {
    /// The agent workstream/session that owns the task.
    public var workstreamId: String
    /// The task id assigned by that agent.
    public var taskId: String

    /// Creates an agent-task reference.
    public init(workstreamId: String, taskId: String) {
        self.workstreamId = workstreamId
        self.taskId = taskId
    }
}
