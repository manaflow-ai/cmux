import CMUXAgentLaunch
import Foundation

/// Durable workspace destinations for one Claude task list.
struct ClaudeHookTaskListDestinationRecord: Codable, Equatable {
    /// Hard cap for task-list identities retained for deletion cleanup.
    static let maximumRecordCount = 128

    /// The profile that owns the task list, or `nil` for legacy state.
    let taskStoreIdentity: ClaudeTaskStoreIdentity?
    /// The canonical direct-child name under the task-store root.
    let taskListID: String
    /// Workspaces that have received this checklist owner.
    let workspaceIDs: [String]
    /// The last successful delivery or cleanup reconciliation.
    let updatedAt: TimeInterval
}
