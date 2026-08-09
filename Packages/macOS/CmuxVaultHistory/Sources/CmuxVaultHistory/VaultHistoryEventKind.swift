import Foundation

/// A locale-independent category for one History timeline event.
public enum VaultHistoryEventKind: String, Codable, CaseIterable, Sendable {
    /// A workspace was created by the user or an external command.
    case workspaceCreated
    /// A user-assigned workspace title changed.
    case workspaceRenamed
    /// A workspace was explicitly closed.
    case workspaceClosed
    /// A main cmux window was opened.
    case windowOpened
    /// A main cmux window was explicitly closed.
    case windowClosed
    /// An agent session was projected from the durable session index.
    case sessionActivity
}
