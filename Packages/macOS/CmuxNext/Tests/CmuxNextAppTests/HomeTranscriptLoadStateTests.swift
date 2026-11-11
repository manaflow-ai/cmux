import AppKit
@testable import CmuxHomeCore
@testable import CmuxNextHome
import Foundation
import Testing

/// ui-state-fixes M1: a Chief with history whose first transcript read failed showed the first-run
/// panel (an empty window looked like a new Chief); it shows "Couldn't load messages." with Try
/// Again instead, and "Loading messages…" while the read is out with nothing to draw. A truly new
/// Chief still shows the first-run panel.
@MainActor @Suite(.serialized) struct HomeTranscriptLoadStateTests {
    let id = ConversationID("conv_chief")

    /// Yields to the main actor until `done` or a 5 s deadline (the observation's hop runs meanwhile).
    func settle(_ done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline { await Task.yield() }
    }

    /// A Chief whose first read fails shows the error, never the first-run panel: the store cannot
    /// tell a Chief with history from a new one until a read answers. With nothing to draw meanwhile
    /// (an inbox that names no newest message) the panel says loading, then failed with Try Again.
    @Test func aFailedFirstReadShowsRetryNotTheFirstRunPanel() async throws {
        let source = GatedHomeSource(EmptyChiefSource())
        let store = HomeStore(source: source)
        let me = try await source.inbox().me.id
        store.start()
        defer { store.stop() }
        await settle { store.isOnline && !store.rows.isEmpty }
        source.failReads(true)
        source.hold()
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: me)
        defer { view.stop() }
        #expect(view.debugTranscriptLoadState == "loading", "an uncached transcript drew blank while its first page loaded")
        #expect(view.firstRun.isHidden)
        source.release()
        await view.binding.opened()
        await settle { view.debugTranscriptLoadState == "failed" }
        #expect(view.debugTranscriptLoadState == "failed")
        #expect(view.firstRun.isHidden, "a Chief whose read failed showed the first-run panel")
        #expect(!view.loadState.retry.isHidden)

        source.failReads(false)
        view.loadState.retry.performClick(nil)
        await settle { store.transcriptFirstPage(id) == .loaded && view.debugTranscriptLoadState == nil }
        #expect(view.debugTranscriptLoadState == nil)
        #expect(!view.firstRun.isHidden, "a Chief that is truly new shows the first-run panel once read")
    }

    /// A Chief with history: the inbox's newest message draws at once while the first page loads
    /// (HomeMirror.beginLoadingWithNewest), so the transcript is never blank, and a failed first
    /// read still never shows the first-run panel; Try Again brings the rest.
    @Test func aChiefWithHistoryDrawsItsNewestAndNeverTheFirstRunPanel() async throws {
        let source = GatedHomeSource(MockHomeSource(options: .immediate))
        let store = HomeStore(source: source)
        store.start()
        defer { store.stop() }
        await settle { store.me != nil && store.isOnline && !store.rows.isEmpty }
        let me = try #require(store.me?.id)
        source.failReads(true)
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: me)
        defer { view.stop() }
        await settle { !store.transcript(for: id).isEmpty }
        #expect(store.transcript(for: id).count == 1, "the inbox's newest message did not draw at once")
        await view.binding.opened()
        await settle { store.transcriptFirstPage(id) == .failed }
        #expect(store.transcriptFirstPage(id) == .failed)
        #expect(view.firstRun.isHidden, "a Chief with history whose read failed showed the first-run panel")

        source.failReads(false)
        await store.retryTranscript(id).value
        #expect(store.transcriptFirstPage(id) == .loaded)
        #expect(store.transcript(for: id).count > 1)
        #expect(view.firstRun.isHidden, "a Chief with history never shows the first-run panel")
    }

    /// Round 2 (verifier low): Try Again on a failed older page started a Task nobody held, so
    /// `stop()` could not end it. The view keeps it and `stop()` cancels it.
    @Test func stopCancelsTheOlderPageRetry() async throws {
        let source = GatedHomeSource(MockHomeSource(options: .immediate))
        let store = HomeStore(source: source)
        store.start()
        defer { store.stop() }
        await settle { store.me != nil && store.isOnline && !store.rows.isEmpty }
        let me = try #require(store.me?.id)
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: me)
        await view.binding.opened()
        view.retryOlder()
        let retry = try #require(view.olderRetry, "Try Again's older-page read is not held")
        // A second Try Again replaces the first.
        view.retryOlder()
        #expect(retry.isCancelled)
        let second = try #require(view.olderRetry)
        view.stop()
        #expect(second.isCancelled, "stop() left the older-page retry running")
        #expect(view.olderRetry == nil)
    }

    @Test func aTrulyNewChiefStillShowsTheFirstRunPanel() async throws {
        let source = EmptyChiefSource()
        let store = HomeStore(source: source)
        let inbox = try await source.inbox()
        store.start()
        defer { store.stop() }
        await store.open(id)
        let view = HomeNativeTranscriptView(store: store, conversation: id, me: inbox.me.id)
        defer { view.stop(); store.close(id) }
        await view.binding.opened()
        #expect(view.debugTranscriptLoadState == nil)
        #expect(!view.firstRun.isHidden)
    }
}
