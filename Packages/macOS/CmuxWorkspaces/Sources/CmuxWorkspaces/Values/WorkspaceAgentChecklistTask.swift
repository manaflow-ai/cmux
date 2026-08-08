public import Foundation

/// One agent-reported task, already mapped onto workspace-checklist
/// vocabulary by the caller.
public struct WorkspaceAgentChecklistTask: Sendable, Equatable {
    /// The stable checklist identity derived from the agent's task id.
    public let id: UUID
    /// The agent task this row mirrors, persisted with the row.
    public let ref: WorkspaceAgentTaskRef
    /// The task text to display.
    public let text: String
    /// The completion state the agent reported.
    public let state: WorkspaceChecklistItem.State

    /// Creates an agent-reported checklist task.
    ///
    /// - Parameters:
    ///   - id: The stable checklist identity for the agent's task.
    ///   - text: The task text (normalized by the sync).
    ///   - state: The completion state the agent reported.
    ///   - ref: The agent task this row mirrors.
    public init(
        id: UUID,
        ref: WorkspaceAgentTaskRef,
        text: String,
        state: WorkspaceChecklistItem.State
    ) {
        self.id = id
        self.ref = ref
        self.text = text
        self.state = state
    }
}
