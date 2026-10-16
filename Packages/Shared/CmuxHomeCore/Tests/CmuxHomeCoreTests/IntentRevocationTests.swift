import Foundation
import Testing
@testable import CmuxHomeCore

/// `HomeEvent.intentsRevoked`: the owner will never apply these intents (the
/// account that made them is gone), so the store drops them in every state
/// and the next recovery resends nothing of them.
@Suite struct IntentRevocationTests {
    let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
    let conv = ConversationID("conv_a")

    @Test func revokeDropsEveryStateAndKeepsTheRest() {
        var log = IntentLog()
        let failed = HomeIntent(key: IdempotencyKey("k_failed"), op: .sendMessage(conversation: conv, parts: [.text("a")]))
        let waiting = HomeIntent(key: IdempotencyKey("k_waiting"), op: .startConversation(contacts: [.email("x@y.com")], firstMessage: []))
        let kept = HomeIntent(key: IdempotencyKey("k_kept"), op: .setReadCursor(conversation: conv, seq: 1))
        for intent in [failed, waiting, kept] { log.append(intent) }
        log.fail(failed.key, .invalid("x"))
        log.markUnconfirmed(waiting.key)
        log.markUnconfirmed(kept.key)
        let revoked = log.revoke([failed.key, waiting.key])
        #expect(revoked == [failed.op, waiting.op])
        #expect(log.entries.map(\.intent.key) == [kept.key])
        #expect(log.takeResends() == [kept])
    }

    @MainActor @Test func theStoreDropsRevokedIntentsAndRedrawsTheirTranscript() async {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.handle(.connection(.online))
        let summary = ConversationSummary(id: conv, participants: [me], lastSeq: 0, rev: 1,
                                          createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
        store.handle(.inbox(InboxSnapshot(me: me, conversations: [summary], rev: 1)))
        // The mock does not know this conversation: the send fails and stays as Not Delivered.
        let key = IdempotencyKey("k_send")
        await #expect(throws: HomeRejection.invalid("unknown_conversation")) {
            try await store.perform(.sendMessage(conversation: conv, parts: [.text("a")]), key: key)
        }
        #expect(store.transcript(for: conv).count == 1)
        let before = store.transcriptVersion[conv] ?? 0
        store.handle(.intentsRevoked([key]))
        #expect(store.log.isEmpty)
        #expect(store.transcript(for: conv).isEmpty)
        #expect((store.transcriptVersion[conv] ?? 0) > before)
    }
}
