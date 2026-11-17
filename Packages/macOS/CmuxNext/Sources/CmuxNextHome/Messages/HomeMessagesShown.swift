public import CmuxHomeCore

/// What the Messages page shows, as it last said (`cmux.home.messages.selected`). New Message is its
/// own state, not "nothing open": the conversation open before it stays ``conversation``, so the
/// dock's Messages to Channels switch and an action on the shown conversation still find it.
public struct HomeMessagesShown: Equatable, Sendable {
    /// The open conversation (kept while New Message shows).
    public private(set) var conversation: ConversationID?
    /// New Message shows on the page (it reports no conversation then).
    public private(set) var composing = false
    /// The page said what it shows at least once (its inbox is read).
    public private(set) var reported = false

    public init() {}

    /// The page reported `id` (nil: none) and whether New Message shows. Returns nil when nothing
    /// changed (a repeat report), else whether the open conversation moved.
    public mutating func report(_ id: ConversationID?, composing: Bool) -> Bool? {
        let next = composing ? conversation : id
        guard !reported || next != conversation || composing != self.composing else { return nil }
        defer { (reported, conversation, self.composing) = (true, next, composing) }
        return next != conversation
    }
}
