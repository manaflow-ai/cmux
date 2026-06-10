import Foundation
import Testing

@testable import CmuxAgentConversation

/// Behavioral tests for ``ConversationDelta/compute(from:to:)``.
@Suite struct ConversationDeltaTests {
    /// Builds a conversation from `(id, text)` pairs.
    private func conversation(_ pairs: [(String, String)]) -> Conversation {
        Conversation(
            id: "sess",
            agentKind: .claudeCode,
            sessionId: "sess",
            messages: pairs.map { Message(id: $0.0, role: .assistant, blocks: [.text($0.1)]) },
            seq: UInt64(pairs.count)
        )
    }

    @Test func identicalParsesAreUnchanged() {
        let old = conversation([("a", "one"), ("b", "two")])
        let new = conversation([("a", "one"), ("b", "two")])
        #expect(ConversationDelta.compute(from: old, to: new) == .unchanged)
    }

    @Test func appendedMessagesAreUpserts() {
        let old = conversation([("a", "one")])
        let new = conversation([("a", "one"), ("b", "two"), ("c", "three")])
        let delta = ConversationDelta.compute(from: old, to: new)
        #expect(delta == .appendedOrChanged(Array(new.messages[1...])))
    }

    @Test func grownLastMessageIsUpsertedById() {
        let old = conversation([("a", "one"), ("b", "tw")])
        let new = conversation([("a", "one"), ("b", "two")])
        let delta = ConversationDelta.compute(from: old, to: new)
        #expect(delta == .appendedOrChanged([new.messages[1]]))
    }

    @Test func shorterParseIsTruncated() {
        let old = conversation([("a", "one"), ("b", "two")])
        let new = conversation([("a", "one")])
        #expect(ConversationDelta.compute(from: old, to: new) == .truncated)
    }

    @Test func rewrittenPrefixIsTruncated() {
        let old = conversation([("a", "one"), ("b", "two")])
        let new = conversation([("x", "other"), ("y", "history"), ("z", "entirely")])
        #expect(ConversationDelta.compute(from: old, to: new) == .truncated)
    }

    @Test func emptyToNonEmptyIsUpsert() {
        let old = conversation([])
        let new = conversation([("a", "one")])
        #expect(ConversationDelta.compute(from: old, to: new) == .appendedOrChanged(new.messages))
    }
}
