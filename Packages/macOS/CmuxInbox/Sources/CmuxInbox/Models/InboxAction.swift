import Foundation

/// A user-visible action that may be available for a thread or item.
public enum InboxAction: String, Codable, CaseIterable, Sendable, Hashable {
    /// Mark an item or thread read.
    case markRead
    /// Mark an item or thread unread.
    case markUnread
    /// Open the original source app or web thread.
    case openOriginal
    /// Create or update a local reply draft.
    case draftReply
    /// Send a reply after explicit user approval.
    case sendApprovedReply
    /// Archive the thread when supported by the source.
    case archive
    /// Mute the thread when supported by the source.
    case mute
}
