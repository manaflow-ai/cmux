import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

/// The user, 2026-10-21: "switching between different chiefs and messages/conversations needs
/// instant loading of messages." A conversation switched away from keeps its transcript in
/// memory (the most recent ``HomeMirror/keptLimit`` of them), so switching back draws it on the
/// switch, never an empty transcript while the owner answers; the read that follows reconciles
/// what was said meanwhile.
@MainActor
@Suite struct StoreKeptTranscriptTests {
    let id = ConversationID("conv_aziz")

    func started() async -> (HomeStore, GatedHomeSource, MockHomeSource) {
        let mock = MockHomeSource(options: .immediate)
        let source = GatedHomeSource(mock)
        let store = HomeStore(source: source)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        return (store, source, mock)
    }

    @Test func aConversationOpenedAgainDrawsAtOnceWhileItsReadIsOut() async {
        let (store, source, _) = await started()
        await store.open(id)
        let shown = store.transcript(for: id).map(\.id)
        #expect(!shown.isEmpty)
        store.close(id)

        source.hold()
        let reopening = store.beginOpen(id)
        // On the switch itself, before the owner answers anything.
        #expect(store.transcript(for: id).map(\.id) == shown, "switching back drew an empty transcript")
        await waitUntil { source.waiting == 1 }
        source.release()
        await reopening.value
        // It still reads, so the source sets up again what the close ended.
        #expect(source.snapshots == [id, id])
        #expect(store.mirror.windows[id] != nil)
        store.stop()
    }

    @Test func whatWasSaidWhileAwayLandsFromTheReadAfterTheSwitch() async throws {
        let (store, source, mock) = await started()
        await store.open(id)
        store.close(id)
        let author = try #require(store.summary(id)?.participants.first { $0.id != store.me?.id }?.id)
        let posted = try #require(await mock.post("said while away", from: author, in: id, key: IdempotencyKey("k_away")))
        await store.open(id)
        #expect(store.mirror.windows[id]?.messages.contains { $0.seq == posted } == true)
        #expect(source.snapshots == [id, id])
        store.stop()
    }
}

/// The mirror's kept transcripts: bounded, never live, and gone with their conversation.
@Suite struct MirrorKeptTranscriptTests {
    let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
    let other = Participant(id: ParticipantID("user_o"), kind: .human, displayName: "O")

    func summary(_ conv: ConversationID, rev: Revision = 1, lastSeq: Seq = 1) -> ConversationSummary {
        ConversationSummary(id: conv, participants: [me, other], lastSeq: lastSeq, rev: rev,
                            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    func message(_ conv: ConversationID, _ seq: Seq) -> Message {
        Message(id: MessageID("\(conv.rawValue)-m\(seq)"), conversation: conv, seq: seq,
                clientMessageID: IdempotencyKey("\(conv.rawValue)-k\(seq)"), author: other.id,
                parts: [.text("t\(seq)")], createdAt: Date(timeIntervalSince1970: Double(seq)))
    }

    func opened(_ ids: [ConversationID]) -> HomeMirror {
        var mirror = HomeMirror()
        mirror.apply(inbox: InboxSnapshot(me: me, conversations: ids.map { summary($0) }, rev: 1))
        for conv in ids {
            mirror.beginLoading(conv)
            mirror.apply(page: ConversationPage(conversation: summary(conv), messages: [message(conv, 1)]))
        }
        return mirror
    }

    @Test func aClosedTranscriptIsKeptAndRestoredStale() {
        let conv = ConversationID("conv_a")
        var mirror = opened([conv])
        mirror.endTranscript(conv)
        #expect(mirror.windows[conv] == nil, "a kept transcript is not a live window")
        let restored = mirror.restoreKept(conv)
        #expect(restored)
        #expect(mirror.windows[conv]?.messages.map(\.seq) == [1])
        // Nothing settles against it until a read catches it up.
        #expect(mirror.isStale(.conversation(conv)))
    }

    @Test func keepsOnlyTheMostRecentlyClosed() {
        let ids = (0...HomeMirror.keptLimit).map { ConversationID("conv_\($0)") }
        var mirror = opened(ids)
        for conv in ids { mirror.endTranscript(conv) }
        let oldest = mirror.restoreKept(ids[0])
        let second = mirror.restoreKept(ids[1])
        let newest = mirror.restoreKept(ids.last!)
        #expect(!oldest, "the oldest closed transcript outlived the bound")
        #expect(second)
        #expect(newest)
    }

    @Test func aRemovedConversationTakesItsKeptTranscriptWithIt() {
        let gone = ConversationID("conv_gone")
        let stays = ConversationID("conv_stays")
        var mirror = opened([gone, stays])
        mirror.endTranscript(gone)
        mirror.endTranscript(stays)
        mirror.apply(inbox: InboxSnapshot(me: me, conversations: [summary(stays)], rev: 2))
        let goneBack = mirror.restoreKept(gone)
        let staysBack = mirror.restoreKept(stays)
        #expect(!goneBack)
        #expect(staysBack)
    }
}
