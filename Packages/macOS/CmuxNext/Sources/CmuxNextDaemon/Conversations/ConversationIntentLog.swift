public import Foundation

/// One `message.send` the user made that the owner has not confirmed.
public struct PendingConversationSend: Sendable, Hashable, Identifiable {
    public enum State: Sendable, Hashable {
        /// Sent (or waiting to be resent after a reconnect).
        case sending
        /// The owner answered; it leaves the log once the mirror reaches `rev`.
        case acknowledged(rev: UInt64)
        /// The owner rejected it, or it could not be sent. Kept as a failed
        /// draft the user can retry (same key) or discard.
        case failed(reason: String)
    }

    /// Also the op's idempotency key.
    public let clientMsgID: String
    public let conversation: String
    public let parts: [ConversationPart]
    public let replyTo: ConversationPartRef?
    public let createdAt: Date
    public var state: State

    public var id: String { clientMsgID }

    public init(clientMsgID: String, conversation: String, parts: [ConversationPart], replyTo: ConversationPartRef?,
                createdAt: Date, state: State = .sending) {
        self.clientMsgID = clientMsgID
        self.conversation = conversation
        self.parts = parts
        self.replyTo = replyTo
        self.createdAt = createdAt
        self.state = state
    }

    public var op: ConversationOp { .send(clientMsgID: clientMsgID, parts: parts, replyTo: replyTo) }
}

/// The ordered log of unconfirmed sends for one conversation. Visible
/// transcript = mirror tail + these entries. An entry leaves on its echo (the
/// mirror holds a message with its client id) or once the mirror reaches the
/// revision the owner acknowledged it at; a reject turns it into a failed draft.
public struct ConversationIntentLog: Sendable, Equatable {
    public private(set) var entries: [PendingConversationSend] = []

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// Appends a send; false when the client id is already in the log.
    @discardableResult
    public mutating func add(_ send: PendingConversationSend) -> Bool {
        guard !entries.contains(where: { $0.clientMsgID == send.clientMsgID }) else { return false }
        entries.append(send)
        return true
    }

    /// The owner committed (or replayed) the send at `rev`.
    public mutating func acknowledge(_ clientMsgID: String, rev: UInt64) {
        guard let index = entries.firstIndex(where: { $0.clientMsgID == clientMsgID }) else { return }
        entries[index].state = .acknowledged(rev: rev)
    }

    public mutating func reject(_ clientMsgID: String, reason: String) {
        guard let index = entries.firstIndex(where: { $0.clientMsgID == clientMsgID }) else { return }
        entries[index].state = .failed(reason: reason)
    }

    /// A failed draft goes back to sending (retry with the same key).
    @discardableResult
    public mutating func retry(_ clientMsgID: String) -> PendingConversationSend? {
        guard let index = entries.firstIndex(where: { $0.clientMsgID == clientMsgID }) else { return nil }
        entries[index].state = .sending
        return entries[index]
    }

    public mutating func discard(_ clientMsgID: String) {
        entries.removeAll { $0.clientMsgID == clientMsgID }
    }

    /// Drops every entry the mirror now confirms. Returns the client ids that left.
    @discardableResult
    public mutating func settle(against mirror: ConversationMirror) -> [String] {
        var settled: [String] = []
        entries.removeAll { entry in
            let echoed = mirror.message(clientMsgID: entry.clientMsgID) != nil
            let reached: Bool
            if case .acknowledged(let rev) = entry.state { reached = mirror.rev >= rev } else { reached = false }
            if echoed || reached { settled.append(entry.clientMsgID) }
            return echoed || reached
        }
        return settled
    }

    /// Sends to repeat after a reconnect: everything still sending, in order.
    /// The owner applies a repeated key once.
    public var resendable: [PendingConversationSend] {
        entries.filter { $0.state == .sending }
    }
}
