import Foundation

/// Per-conversation state the conversation list owns, as Messages keeps it:
/// pinned (with a position among pins), alerts hidden, manually marked
/// unread, and deleted (recoverable, so the conversation still exists).
public struct ConversationListState: Sendable, Hashable {
    public var pinned: Bool
    /// Position among pinned conversations, ascending. Nil when not pinned.
    public var pinOrder: Int?
    /// Hide Alerts.
    public var muted: Bool
    /// Mark as Unread. Cleared when the conversation is opened.
    public var markedUnread: Bool
    /// Moved to Recently Deleted. A new incoming message brings it back.
    public var deleted: Bool
    /// The details panel's Send Read Receipts for this conversation. While
    /// off, reading still clears unread here but others are not told.
    public var sendReadReceipts: Bool

    public init(pinned: Bool = false, pinOrder: Int? = nil, muted: Bool = false, markedUnread: Bool = false, deleted: Bool = false, sendReadReceipts: Bool = true) {
        self.pinned = pinned
        self.pinOrder = pinOrder
        self.muted = muted
        self.markedUnread = markedUnread
        self.deleted = deleted
        self.sendReadReceipts = sendReadReceipts
    }

    /// The state after `change`, with the same invariants the server keeps:
    /// unpinning clears the order, deleting unpins and clears Mark as Unread.
    public func applying(_ change: ConversationListStateChange) -> ConversationListState {
        var next = self
        if let pinned = change.pinned {
            next.pinned = pinned
            if !pinned { next.pinOrder = nil }
        }
        if let pinOrder = change.pinOrder, next.pinned { next.pinOrder = pinOrder }
        if let muted = change.muted { next.muted = muted }
        if let markedUnread = change.markedUnread { next.markedUnread = markedUnread }
        if let sendReadReceipts = change.sendReadReceipts { next.sendReadReceipts = sendReadReceipts }
        if let deleted = change.deleted {
            next.deleted = deleted
            if deleted {
                next.pinned = false
                next.pinOrder = nil
                next.markedUnread = false
            }
        }
        return next
    }
}

/// A partial update to `ConversationListState`; nil fields stay as they are.
public struct ConversationListStateChange: Sendable, Hashable {
    public var pinned: Bool?
    public var pinOrder: Int?
    public var muted: Bool?
    public var markedUnread: Bool?
    public var deleted: Bool?
    public var sendReadReceipts: Bool?

    public init(pinned: Bool? = nil, pinOrder: Int? = nil, muted: Bool? = nil, markedUnread: Bool? = nil, deleted: Bool? = nil, sendReadReceipts: Bool? = nil) {
        self.pinned = pinned
        self.pinOrder = pinOrder
        self.muted = muted
        self.markedUnread = markedUnread
        self.deleted = deleted
        self.sendReadReceipts = sendReadReceipts
    }

    public var isEmpty: Bool {
        pinned == nil && pinOrder == nil && muted == nil && markedUnread == nil && deleted == nil && sendReadReceipts == nil
    }
}

/// How a conversation list arranges conversations, shared by every platform's
/// list: pins on top in pin order (at most `maxPinned`), then everything else
/// newest first; deleted conversations are not listed.
public enum ConversationListArrangement {
    /// Messages: "You can pin up to 9 conversations."
    public static let maxPinned = 9

    public struct Item<ID: Hashable>: Sendable where ID: Sendable {
        public var id: ID
        public var state: ConversationListState
        public var lastActivity: Date

        public init(id: ID, state: ConversationListState, lastActivity: Date) {
            self.id = id
            self.state = state
            self.lastActivity = lastActivity
        }
    }

    public static func arrange<ID: Hashable & Comparable & Sendable>(_ items: [Item<ID>]) -> (pinned: [ID], others: [ID]) {
        let listed = items.filter { !$0.state.deleted }
        let pinned = listed.filter(\.state.pinned).sorted {
            let lhs = $0.state.pinOrder ?? Int.max, rhs = $1.state.pinOrder ?? Int.max
            return lhs != rhs ? lhs < rhs : $0.id < $1.id
        }
        let others = listed.filter { !$0.state.pinned }.sorted {
            $0.lastActivity != $1.lastActivity ? $0.lastActivity > $1.lastActivity : $0.id < $1.id
        }
        return (pinned.map(\.id), others.map(\.id))
    }

    /// Whether one more conversation may be pinned.
    public static func canPin(pinnedCount: Int) -> Bool {
        pinnedCount < maxPinned
    }

    /// Pin orders after moving `id` to `index` among `pinned` (inserting it
    /// when it is not pinned yet). Only conversations whose order changes are
    /// returned, so a reorder touches as few conversations as possible.
    public static func pinOrders<ID: Hashable>(pinned: [ID], current: [ID: Int], moving id: ID, to index: Int) -> [ID: Int] {
        var ids = pinned.filter { $0 != id }
        ids.insert(id, at: max(0, min(index, ids.count)))
        var changed: [ID: Int] = [:]
        for (order, each) in ids.enumerated() where current[each] != order {
            changed[each] = order
        }
        return changed
    }
}
