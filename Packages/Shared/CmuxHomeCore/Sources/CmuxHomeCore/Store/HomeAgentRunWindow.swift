public import Foundation

/// Only runs anchored to the messages this transcript currently has loaded are hydrated.
public struct HomeAgentRunWindow: Hashable, Sendable {
    public var turns: Set<IdempotencyKey>
    public var turnsByAuthor: [ParticipantID: Set<IdempotencyKey>]
    public var messageIDs: Set<MessageID>
    public var oldestMessageAt: Date?

    public init(messages: [Message]) {
        turns = Set(messages.map(\.clientMessageID))
        turnsByAuthor = Dictionary(grouping: messages, by: \.author).mapValues { Set($0.map(\.clientMessageID)) }
        messageIDs = Set(messages.map(\.id))
        oldestMessageAt = messages.map(\.createdAt).min()
    }

    public func contains(turn: String?, answers: [String]) -> Bool {
        if let turn, turns.contains(IdempotencyKey(turn)) { return true }
        return answers.contains { messageIDs.contains(MessageID($0)) }
    }
}
