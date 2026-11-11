import AppKit
@testable import CmuxHomeCore
@testable import CmuxNextHome
import Foundation
import Testing

/// ui-state-fixes M1: a Chief with history whose first transcript read failed showed the first-run
/// panel (an empty window looked like a new Chief); it shows "Couldn't load messages." with Try
/// Again instead, and "Loading messages…" while the read is out. A truly new Chief still shows the
/// first-run panel.
@MainActor @Suite(.serialized) struct HomeTranscriptLoadStateTests {
    let id = ConversationID("conv_chief")

    /// Yields to the main actor until `done` or a 5 s deadline (the observation's hop runs meanwhile).
    func settle(_ done: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !done(), ContinuousClock.now < deadline { await Task.yield() }
    }

    @Test func aFailedFirstReadShowsRetryNotTheFirstRunPanel() async throws {
        let source = GatedHomeSource(MockHomeSource(options: .immediate))
        let store = HomeStore(source: source)
        store.start()
        defer { store.stop() }
        await settle { store.me != nil && store.isOnline && !store.rows.isEmpty }
        let me = try #require(store.me?.id)
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
        #expect(view.firstRun.isHidden, "a Chief with history whose read failed showed the first-run panel")
        #expect(!view.loadState.retry.isHidden)

        source.failReads(false)
        view.loadState.retry.performClick(nil)
        await settle { view.debugTranscriptLoadState == nil && !store.transcript(for: id).isEmpty }
        #expect(view.debugTranscriptLoadState == nil)
        #expect(!store.transcript(for: id).isEmpty)
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
