import Foundation
import Testing
import CmuxHomeCoreTestSupport
@testable import CmuxHomeCore

/// "Open" means on screen now (round-5 review, major 1): a page read for a
/// transcript that closed while the read ran is dropped, and an open made
/// while a read ran reads again after it, so the source sets up again
/// what the close ended (a cloud subscription).
@MainActor
@Suite struct StoreOpenCloseTests {
    let id = ConversationID("conv_aziz")

    func started() async -> (HomeStore, GatedHomeSource) {
        let source = GatedHomeSource(MockHomeSource(options: .immediate))
        let store = HomeStore(source: source)
        store.start()
        await waitUntil { store.isOnline && !store.rows.isEmpty }
        return (store, source)
    }

    @Test func aTranscriptClosedDuringItsFirstPageStaysClosed() async {
        let (store, source) = await started()
        source.hold()
        let opening = Task { await store.open(id) }
        await waitUntil { source.waiting == 1 }
        store.close(id)
        source.release()
        await opening.value
        #expect(store.mirror.windows[id] == nil, "the page read before the close put the transcript back")
        // The close, and again once the read returned.
        #expect(source.closes == [id, id])

        // Opened again, it reads again: the source subscribes again after the close ended it.
        await store.open(id)
        #expect(source.snapshots == [id, id], "the reopen found the stale window and read nothing")
        #expect(!store.transcript(for: id).isEmpty)
        store.stop()
    }

    /// A source reads off the main actor, so a close can reach it before
    /// the read set anything up (round-6 review, finding 1): the cloud
    /// source then ends nothing, and the read subscribes after it. The store
    /// closes the source again once a read of a closed transcript returns.
    @Test func aCloseDuringAReadClosesTheSourceAgainAfterTheReadReturns() async {
        let (store, source) = await started()
        source.hold()
        let opening = Task { await store.open(id) }
        await waitUntil { source.waiting == 1 }
        store.close(id)
        source.release()
        await opening.value
        #expect(source.journal.last == .close(id), "nothing closed what the read set up after the close: \(source.journal)")
        #expect(source.journal.firstIndex(of: .readReturned(id)).map { $0 < source.journal.count - 1 } == true)
        #expect(store.viewers[id] == nil)
        store.stop()
    }

    @Test func anOpenDuringAReadThatAClosePrecededReadsAgain() async {
        let (store, source) = await started()
        source.hold()
        let first = Task { await store.open(id) }
        await waitUntil { source.waiting == 1 }
        store.close(id)
        let second = Task { await store.open(id) }
        await waitUntil { store.mirror.windows[id] != nil }
        source.release()
        await first.value
        await second.value
        #expect(source.snapshots == [id, id], "the open during the read never read again, so nothing subscribed")
        #expect(!store.transcript(for: id).isEmpty)
        store.close(id)
        #expect(source.closes == [id, id])
        store.stop()
    }

    /// A conversation shown nowhere is not read on a gap: the read would
    /// subscribe it at a cloud source, and no close would end that.
    @Test func aGapInAConversationShownNowhereReadsNothing() async throws {
        let (store, source) = await started()
        let summary = try #require(store.summary(id))
        let rev = store.mirror.revision(of: .conversation(id)) + 5
        let message = Message(id: MessageID("m_gap"), conversation: id, seq: summary.lastSeq + 5,
                              clientMessageID: IdempotencyKey("k_gap"), author: ParticipantID("user_aziz"),
                              parts: [.text("later")], createdAt: Date())
        store.handle(.message(message, rev: rev))
        for _ in 0..<200 { await Task.yield() }
        #expect(source.snapshots.isEmpty, "a gap read a transcript nobody shows")
        #expect(store.mirror.windows[id] == nil)
        #expect(!store.mirror.isStale(.conversation(id)))
        store.stop()
    }
}
