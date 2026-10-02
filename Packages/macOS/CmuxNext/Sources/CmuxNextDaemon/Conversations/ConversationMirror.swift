import Foundation

/// The confirmed projection of one local conversation
/// (OWNERSHIP-PRINCIPLES.md "Clients are projections"). Only the owner's
/// committed changes write it: `conversation-changed` events and the reply to
/// one of our own ops, both carrying the owner's `rev`. It keeps the head and a
/// bounded tail of the newest messages; older pages are read on demand and
/// never stored here, so the client never holds the full log.
public struct ConversationMirror: Sendable, Equatable {
    public private(set) var summary: ConversationSummary
    /// The newest confirmed messages, ascending and contiguous by seq.
    public private(set) var tail: [ConversationMessage]
    public let tailLimit: Int

    public var id: String { summary.id }
    public var rev: UInt64 { summary.rev }

    public enum Outcome: Sendable, Equatable {
        case applied(ConversationChange)
        /// Already applied (a duplicate or a change older than the mirror).
        case stale
        /// A revision was skipped: refetch the snapshot.
        case gap
    }

    public init(snapshot: ConversationSnapshot, tailLimit: Int = 400) {
        summary = snapshot.conversation
        self.tailLimit = max(1, tailLimit)
        tail = Array(snapshot.messages.suffix(self.tailLimit))
    }

    /// Applies one committed change at `rev`.
    public mutating func apply(rev: UInt64, change: ConversationChange) -> Outcome {
        guard rev > summary.rev else { return .stale }
        guard rev == summary.rev + 1 else { return .gap }
        summary.rev = rev
        switch change {
        case .message(let message):
            summary.lastSeq = max(summary.lastSeq, message.seq)
            summary.lastMessage = message
            summary.updatedAt = message.createdAt
            if let last = tail.last, message.seq != last.seq + 1 {
                // A new message the tail cannot join contiguously: restart the tail there.
                tail = [message]
            } else {
                tail.append(message)
                if tail.count > tailLimit { tail.removeFirst(tail.count - tailLimit) }
            }
        case .messageUpdated(let message):
            if let index = tail.firstIndex(where: { $0.id == message.id }) { tail[index] = message }
            if summary.lastMessage?.id == message.id { summary.lastMessage = message }
        case .readCursor(let participant, let seq):
            summary.readCursors[participant] = max(summary.readCursors[participant] ?? 0, seq)
        case .conversation(let head):
            let lastMessage = summary.lastMessage
            summary = head
            summary.rev = rev
            if summary.lastMessage == nil { summary.lastMessage = lastMessage }
        case .unknown:
            break
        }
        return .applied(change)
    }

    public mutating func apply(_ event: ConversationEvent) -> Outcome {
        apply(rev: event.rev, change: event.change)
    }

    /// Replaces everything with a fresh snapshot (after a gap or a reconnect).
    public mutating func reset(_ snapshot: ConversationSnapshot) {
        self = ConversationMirror(snapshot: snapshot, tailLimit: tailLimit)
    }

    /// The confirmed message with this client id, when it is in the tail.
    public func message(clientMsgID: String) -> ConversationMessage? {
        tail.last(where: { $0.clientMsgID == clientMsgID })
    }
}
