import Foundation
import Testing
@testable import CmuxHomeCore

/// The Chief's running reply through the real store (cx-k1uj follow-up): a
/// draft item of a turn that ended never brings that turn's bubble back,
/// whether the turn ended with its posted reply or because a new turn
/// replaced it.
@MainActor @Suite struct DraftTurnTests {
    let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
    let chief = Participant(id: ParticipantID("agent_mux"), kind: .agent, displayName: "Chief")
    let conv = ConversationID("conv_chief")

    func store() -> HomeStore {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.handle(.connection(.online))
        let summary = ConversationSummary(id: conv, title: "", participants: [me, chief], lastSeq: 0, rev: 1,
                                          createdAt: Date(timeIntervalSince1970: 0),
                                          updatedAt: Date(timeIntervalSince1970: 0))
        store.handle(.inbox(InboxSnapshot(me: me, conversations: [summary], rev: 1)))
        return store
    }

    func draft(_ turn: String, seq: UInt64, _ text: String, fresh: Bool = true) -> HomeEvent {
        .draft(HomeDraftUpdate(conversation: conv, participant: chief.id, turn: IdempotencyKey(turn), segment: 0,
                               seq: seq, isTalk: true, text: text, fresh: fresh, done: false))
    }

    @Test func aLateItemOfAReplacedTurnNeverBringsItBack() {
        let store = store()
        store.handle(draft("turn:a", seq: 1, "Alpha"))
        #expect(store.drafts[conv]?.text == "Alpha")
        // Turn B starts before A's last items arrive.
        store.handle(draft("turn:b", seq: 1, "Beta"))
        #expect(store.drafts[conv]?.turn == IdempotencyKey("turn:b"))
        // Late items of A: a delta and a fresh resend.
        store.handle(draft("turn:a", seq: 2, " more", fresh: false))
        store.handle(draft("turn:a", seq: 3, "Alpha more"))
        #expect(store.drafts[conv]?.turn == IdempotencyKey("turn:b"))
        #expect(store.drafts[conv]?.text == "Beta")
    }

    @Test func aLateItemAfterThePostedReplyNeverBringsItBack() {
        let store = store()
        store.handle(draft("turn:a", seq: 1, "Alpha"))
        let reply = Message(id: MessageID("m1"), conversation: conv, seq: 1, clientMessageID: IdempotencyKey("turn:a"),
                            author: chief.id, parts: [.text("Alpha done")], createdAt: Date(timeIntervalSince1970: 1))
        store.handle(.message(reply, rev: 2))
        #expect(store.drafts[conv] == nil)
        store.handle(draft("turn:a", seq: 2, "Alpha late"))
        #expect(store.drafts[conv] == nil)
    }
}
