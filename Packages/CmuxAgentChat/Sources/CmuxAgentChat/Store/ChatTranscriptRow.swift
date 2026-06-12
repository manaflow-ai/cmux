import Foundation

/// One row of the rendered transcript list.
///
/// This is the immutable snapshot the view layer iterates; rows carry
/// everything a cell needs so no view below the list boundary holds a
/// reference back into the store (snapshot-boundary rule).
public enum ChatTranscriptRow: Identifiable, Sendable, Equatable {
    /// A sticky date header ("Today", "June 9").
    case dateHeader(day: Date)
    /// The "unread messages" separator line.
    case unreadSeparator
    /// A transcript message with its computed group rendering info.
    case message(ChatMessageRowSnapshot)
    /// An optimistic outgoing prompt not yet echoed by the transcript.
    case pendingOutbound(ChatPendingOutbound)

    /// Stable identity for list diffing.
    public var id: String {
        switch self {
        case .dateHeader(let day):
            return "day-\(Int(day.timeIntervalSinceReferenceDate))"
        case .unreadSeparator:
            return "unread-separator"
        case .message(let snapshot):
            return "msg-\(snapshot.message.id)"
        case .pendingOutbound(let pending):
            return "pending-\(pending.id)"
        }
    }
}
