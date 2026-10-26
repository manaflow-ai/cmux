import Foundation
import Testing
@testable import CmuxHomeCore

/// A page the owner pushes (`HomeEvent.conversationPage`, after a resubscribe
/// or a gap) applies like a fetched page: an open conversation catches up,
/// including a message the client missed, and a closed one takes only the
/// summary.
@Suite struct ConversationPageEventTests {
    let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
    let bob = Participant(id: ParticipantID("user_bob"), kind: .human, displayName: "Bob")
    let conv = ConversationID("conv_a")

    func summary(lastSeq: Seq, rev: Revision, title: String = "") -> ConversationSummary {
        ConversationSummary(id: conv, title: title, participants: [me, bob], lastSeq: lastSeq, rev: rev,
                            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    func message(_ seq: Seq) -> Message {
        Message(id: MessageID("m\(seq)"), conversation: conv, seq: seq, clientMessageID: IdempotencyKey("k\(seq)"),
                author: bob.id, parts: [.text("t\(seq)")], createdAt: Date(timeIntervalSince1970: Double(seq)))
    }

    /// One op happened while the socket was down: the pushed page carries the
    /// message, which a summary event alone (rev + 1) would have lost.
    @Test func anOpenConversationCatchesUpFromAPushedPage() {
        var mirror = HomeMirror()
        mirror.apply(inbox: InboxSnapshot(me: me, conversations: [summary(lastSeq: 1, rev: 2)], rev: 1))
        mirror.apply(page: ConversationPage(conversation: summary(lastSeq: 1, rev: 2), messages: [message(1)]))
        let outcome = mirror.apply(.conversationPage(ConversationPage(conversation: summary(lastSeq: 2, rev: 3),
                                                                      messages: [message(1), message(2)])))
        #expect(outcome == .applied)
        #expect(mirror.windows[conv]?.messages.map(\.seq) == [1, 2])
        #expect(mirror.revision(of: .conversation(conv)) == 3)
        #expect(mirror.conversations[conv]?.lastSeq == 2)
    }

    @Test func aClosedConversationTakesOnlyTheSummary() {
        var mirror = HomeMirror()
        mirror.apply(inbox: InboxSnapshot(me: me, conversations: [summary(lastSeq: 1, rev: 2)], rev: 1))
        let outcome = mirror.apply(.conversationPage(ConversationPage(conversation: summary(lastSeq: 2, rev: 3, title: "New"),
                                                                      messages: [message(2)])))
        #expect(outcome == .applied)
        #expect(mirror.windows[conv] == nil)
        #expect(mirror.conversations[conv]?.title == "New")
        // An older page never moves it back.
        #expect(mirror.apply(.conversationPage(ConversationPage(conversation: summary(lastSeq: 1, rev: 2), messages: []))) == .ignoredStale)
        #expect(mirror.conversations[conv]?.title == "New")
    }

    @MainActor @Test func theStoreRedrawsTheTranscriptForAPushedPage() async {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.handle(.connection(.online))
        store.handle(.inbox(InboxSnapshot(me: me, conversations: [summary(lastSeq: 0, rev: 1)], rev: 1)))
        store.handle(.conversationPage(ConversationPage(conversation: summary(lastSeq: 1, rev: 2), messages: [message(1)])))
        #expect(store.summary(conv)?.lastSeq == 1)
        #expect(store.transcriptVersion[conv] != nil)
    }
}
