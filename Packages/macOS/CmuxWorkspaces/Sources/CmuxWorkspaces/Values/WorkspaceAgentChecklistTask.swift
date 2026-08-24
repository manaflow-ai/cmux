public import Foundation

/// One normalized task reported by an agent for workspace checklist sync.
public struct WorkspaceAgentChecklistTask: Sendable, Equatable {
    /// Stable checklist identity for the task.
    public let id: UUID
    /// Persisted ownership reference.
    public let ref: WorkspaceAgentTaskRef
    /// Display text.
    public let text: String
    /// Reported checklist state.
    public let state: WorkspaceChecklistItem.State
    /// Last hook activity associated with the task.
    public let lastActivityAt: Date?
    /// Agent/provider display name.
    public let agentName: String?

    /// Creates an agent checklist task.
    public init(
        id: UUID,
        ref: WorkspaceAgentTaskRef,
        text: String,
        state: WorkspaceChecklistItem.State,
        lastActivityAt: Date? = nil,
        agentName: String? = nil
    ) {
        self.id = id
        self.ref = ref
        self.text = text
        self.state = state
        self.lastActivityAt = lastActivityAt
        self.agentName = agentName
    }
}
