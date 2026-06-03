import Foundation

/// The category of a unified inbox item.
public enum UnifiedInboxKind: String, Codable, Equatable, Sendable {
    /// An item backed by an agent conversation.
    case conversation
    /// An item backed by a terminal workspace.
    case workspace
}
