import Testing
@testable import CmuxHomeCore

/// The legacy `conversation-draft-v1` running reply (`HomeDraftBook`): items are numbered, so a
/// repeated or older item is a replay and changes nothing (B5 in
/// plans/cmux-next/home-chat-pipeline-DESIGN.md); only a real jump is a gap.
@Suite struct HomeDraftBookTests {
    let conversation = ConversationID("conv_chief")
    let chief = ParticipantID("agent_chief")
    let turn = IdempotencyKey("turn_1")

    func item(_ seq: UInt64, _ text: String, fresh: Bool = false) -> HomeDraftUpdate {
        HomeDraftUpdate(conversation: conversation, participant: chief, turn: turn, segment: 0, seq: seq,
                        isTalk: true, text: text, fresh: fresh, done: false)
    }

    @Test func aRepeatedItemDoesNotFreezeTheReply() {
        var book = HomeDraftBook()
        _ = book.apply(item(1, "one", fresh: true))
        _ = book.apply(item(2, " two"))
        #expect(book.apply(item(2, " two")) == false, "a repeat changes nothing")
        _ = book.apply(item(3, " three"))
        #expect(book.live[conversation]?.text == "one two three")
    }

    @Test func anOlderItemIsIgnored() {
        var book = HomeDraftBook()
        _ = book.apply(item(1, "one", fresh: true))
        _ = book.apply(item(2, " two"))
        _ = book.apply(item(3, " three"))
        #expect(book.apply(item(2, " two")) == false)
        _ = book.apply(item(4, " four"))
        #expect(book.live[conversation]?.text == "one two three four")
    }

    @Test func aJumpWaitsForTheNextFreshItem() {
        var book = HomeDraftBook()
        _ = book.apply(item(1, "one", fresh: true))
        _ = book.apply(item(3, " three"))
        #expect(book.live[conversation]?.text == "one", "a missed item: nothing new until a fresh item")
        _ = book.apply(item(4, "one two three four", fresh: true))
        #expect(book.live[conversation]?.text == "one two three four")
    }
}
