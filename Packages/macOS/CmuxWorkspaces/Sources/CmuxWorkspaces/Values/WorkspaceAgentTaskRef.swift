public import Foundation

/// Identifies the agent task a checklist row was created from.
///
/// Persisted with the row so ownership survives an app restart, a dropped
/// event, or eviction of the in-memory accumulator: the row itself says which
/// workstream owns it and which task it mirrors, so a later status-only update
/// can find it again instead of being ignored as an unknown id.
public struct WorkspaceAgentTaskRef: Codable, Sendable, Hashable {
    /// The owning workstream (agent session) id.
    public var workstreamId: String
    /// The agent's own task id within that workstream.
    public var taskId: String

    /// Creates a reference to one agent task.
    ///
    /// - Parameters:
    ///   - workstreamId: The owning workstream (agent session) id.
    ///   - taskId: The agent's task id within that workstream.
    public init(workstreamId: String, taskId: String) {
        self.workstreamId = workstreamId
        self.taskId = taskId
    }
}
