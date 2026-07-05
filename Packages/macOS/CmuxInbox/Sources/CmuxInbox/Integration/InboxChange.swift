import Foundation

/// Notification emitted after the local inbox changes.
public enum InboxChange: Sendable, Equatable {
    /// Accounts or connector statuses changed.
    case accounts
    /// Threads, items, drafts, or unread counts changed.
    case items
}
