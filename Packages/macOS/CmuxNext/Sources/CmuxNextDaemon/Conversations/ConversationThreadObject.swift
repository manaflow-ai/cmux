import Foundation

/// A thread root's object (`thread` on a root `Message`, conversation-thread-objects-v1): its title,
/// owner and resolution. Absent fields are unset; the whole object is absent when all are.
public struct ConversationThreadObject: Codable, Sendable, Hashable {
    public var title: String?
    /// The participant who owns the thread (a person or a Chief).
    public var owner: String?
    /// Set by `status: resolved`; the thread reads as resolved only while no live reply has a seq above `seq`.
    public var resolved: Resolution?

    public struct Resolution: Codable, Sendable, Hashable {
        public var by: String
        public var at: String
        public var seq: UInt64
    }

    public init(title: String? = nil, owner: String? = nil, resolved: Resolution? = nil) {
        self.title = title
        self.owner = owner
        self.resolved = resolved
    }
}
