import Foundation

/// A thread root's object (the daemon's `thread`, conversation-thread-objects-v1): its title, owner and
/// resolution. Every view of a conversation (Messages and Channels) reads the same one.
public struct ThreadInfo: Hashable, Sendable, Codable {
    /// Absent: readers show the root's first line.
    public var title: String?
    /// The participant who owns the thread (a person or a Chief).
    public var owner: ParticipantID?
    /// The conversation's last seq when the thread was resolved; nil while open.
    public var resolvedAtSeq: Seq?
    public var resolvedBy: ParticipantID?

    public init(title: String? = nil, owner: ParticipantID? = nil, resolvedAtSeq: Seq? = nil, resolvedBy: ParticipantID? = nil) {
        self.title = title
        self.owner = owner
        self.resolvedAtSeq = resolvedAtSeq
        self.resolvedBy = resolvedBy
    }

    public enum Status: String, Hashable, Sendable, Codable { case open, resolved }

    /// The owner's rule: resolved only while no live reply has a seq above the resolution's.
    public func status(newestReplySeq: Seq?) -> Status {
        guard let resolvedAtSeq else { return .open }
        return (newestReplySeq ?? 0) <= resolvedAtSeq ? .resolved : .open
    }
}

/// A permalink resolved by the conversation's owner (`conversation-link-resolve`).
public struct HomeLinkTarget: Hashable, Sendable {
    /// The message's seq (nil for a conversation link).
    public var seq: Seq?
    /// The message's top thread root (nil when it is not in a thread).
    public var threadRoot: MessageID?
    /// From the thread root down to the message (`[message]` outside a thread).
    public var path: [MessageID]

    public init(seq: Seq?, threadRoot: MessageID?, path: [MessageID]) {
        self.seq = seq
        self.threadRoot = threadRoot
        self.path = path
    }
}
