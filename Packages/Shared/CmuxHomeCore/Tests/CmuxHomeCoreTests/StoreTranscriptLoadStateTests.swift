import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

/// An empty transcript is an empty conversation only once its first page was read
/// (ui-state-fixes M1). Before, a first read that failed left an empty window that looked like a
/// new conversation, so a Chief with history showed its first-run panel; and an uncached chat
/// drew a blank transcript while its first page loaded, with nothing saying so.
@MainActor
@Suite struct StoreTranscriptLoadStateTests {
    let chief = ConversationID("conv_chief")

    func started() async -> (HomeStore, GatedHomeSource) {
        let source = GatedHomeSource(MockHomeSource(options: .immediate))
        let store = HomeStore(source: source)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        return (store, source)
    }

    @Test func anUncachedTranscriptIsLoadingUntilItsFirstPage() async {
        let (store, source) = await started()
        source.hold()
        let opening = store.beginOpen(chief)
        #expect(store.transcriptFirstPage(chief) == .loading)
        await waitUntil { source.waiting == 1 }
        source.release()
        await opening.value
        #expect(store.transcriptFirstPage(chief) == .loaded)
        #expect(!store.transcript(for: chief).isEmpty)
        store.stop()
    }

    @Test func aFailedFirstReadIsAnErrorAndRetryReadsAgain() async {
        let (store, source) = await started()
        source.failReads(true)
        await store.open(chief)
        #expect(store.transcriptFirstPage(chief) == .failed, "a failed first read looked like an empty conversation")
        #expect(store.transcript(for: chief).isEmpty)
        source.failReads(false)
        await store.retryTranscript(chief).value
        #expect(store.transcriptFirstPage(chief) == .loaded)
        #expect(!store.transcript(for: chief).isEmpty)
        store.stop()
    }

    @Test func aRetryOfATranscriptShownNowhereReadsNothing() async {
        let (store, source) = await started()
        await store.retryTranscript(chief).value
        #expect(source.snapshots.isEmpty)
        store.stop()
    }

    @Test func aFailedOlderPageIsRetryable() async throws {
        let (store, source) = await started()
        await store.open(chief)
        #expect(store.hasOlderMessages(in: chief))
        let first = try #require(store.oldestLoadedSeq(in: chief))
        source.failHistory(true)
        await store.loadOlder(chief)
        #expect(store.olderMessagesFailed(in: chief), "a failed older page left nothing to retry from")
        #expect(store.oldestLoadedSeq(in: chief) == first)
        source.failHistory(false)
        await store.loadOlder(chief)
        #expect(!store.olderMessagesFailed(in: chief))
        #expect(try #require(store.oldestLoadedSeq(in: chief)) < first)
        store.stop()
    }
}

/// The mirror's first-page state: loading until a page, failed after a failed read, loaded after
/// any page, an empty one included (a truly new conversation is still an empty conversation).
@Suite struct MirrorFirstPageTests {
    let me = Participant(id: ParticipantID("user_me"), kind: .human, displayName: "Me")
    let other = Participant(id: ParticipantID("user_o"), kind: .human, displayName: "O")
    let conv = ConversationID("conv_new")

    func summary() -> ConversationSummary {
        ConversationSummary(id: conv, participants: [me, other], lastSeq: 0, rev: 1,
                            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func aFailedReadThenAnEmptyPage() {
        var mirror = HomeMirror()
        mirror.apply(inbox: InboxSnapshot(me: me, conversations: [summary()], rev: 1))
        mirror.beginLoading(conv)
        #expect(mirror.windows[conv]?.firstPage == .loading)
        let failed = mirror.markFirstPageFailed(conv)
        #expect(failed)
        #expect(mirror.windows[conv]?.firstPage == .failed)
        let retried = mirror.retryFirstPage(conv)
        #expect(retried)
        #expect(mirror.windows[conv]?.firstPage == .loading)
        mirror.apply(page: ConversationPage(conversation: summary(), messages: []))
        #expect(mirror.windows[conv]?.firstPage == .loaded)
        #expect(mirror.windows[conv]?.messages.isEmpty == true)
        // A loaded window never turns failed.
        let failedAfterLoad = mirror.markFirstPageFailed(conv)
        #expect(!failedAfterLoad)
    }
}
