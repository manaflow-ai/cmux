public import Foundation

/// One task item in a workspace's persisted checklist, writable by the user
/// (sidebar, CLI) and by agents (control socket). Raw values of the nested
/// enums are a control-socket and session wire format; frozen.
public struct WorkspaceChecklistItem: Codable, Sendable, Identifiable, Hashable {
    /// The item's completion state.
    public enum State: String, Codable, Sendable, CaseIterable {
        case pending
        case inProgress = "in-progress"
        case completed
    }

    /// Who created the item.
    public enum Origin: String, Codable, Sendable, CaseIterable {
        case user
        case agent
    }

    /// The item's stable identity.
    public var id: UUID
    /// The task text (trimmed, non-empty, capped by ``WorkspaceChecklist``).
    public var text: String
    /// The completion state.
    public var state: State
    /// Who created the item.
    public var origin: Origin

    /// Creates an item.
    public init(
        id: UUID = UUID(),
        text: String,
        state: State = .pending,
        origin: Origin = .user
    ) {
        self.id = id
        self.text = text
        self.state = state
        self.origin = origin
    }
}
