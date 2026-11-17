import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// Leo, 2026-11-16: a chat on iOS said "Not connected" at the top for the ~7 s it took to
/// reconnect, "but i dont think it shoildve said anything". A conversation that is not live
/// already reads as not connected: its bar stays empty for a normal reconnect and speaks
/// only once the link has been down past ``QuietStatusGate/threshold``.
@MainActor
@Suite struct MacConversationQuietReconnectTests {
    struct Offline: Error {}

    private func session() -> ChiefSession {
        ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil), clock: ImmediateClock())
    }

    @Test func aNormalReconnectNeverPutsABarOverTheOpenConversation() async {
        let loader = MacConversationLoader()
        let open = session()
        await loader.load { open }

        // The link drops (the app came back from the background): the read fails at once.
        await loader.load({ throw Offline() }, tryAgain: {})
        #expect(loader.session === open)
        #expect(!loader.failed)
        #expect(open.barItem == nil)
        #expect(open.unavailableTitle == nil)
        #expect(!loader.isStale)

        // A retry inside the bound fails again: still nothing on screen.
        await loader.load({ throw Offline() }, tryAgain: {})
        #expect(open.barItem == nil)

        // The link is back a few seconds later: the conversation goes live without ever saying anything.
        let live = session()
        await loader.load { live }
        #expect(loader.session === live)
        #expect(live.barItem == nil)
        #expect(open.barItem == nil)
    }

    @Test func aFirstOpenWhileTheLinkComesUpShowsWhatWasKeptWithNoBar() async {
        let loader = MacConversationLoader()
        let kept = session()
        await loader.load({ throw Offline() }, fallback: kept, tryAgain: {})
        #expect(loader.session === kept)
        #expect(kept.barItem == nil)
        #expect(kept.unavailableTitle == nil)
    }

    /// Waits for `condition`, at most `limit` (a bounded test wait, not a sync).
    private func eventually(_ limit: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + limit
        while clock.now < end {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func pastTheQuietBoundTheConversationIsMarkedNotLiveOnce() async {
        let loader = MacConversationLoader(quiet: .milliseconds(30))
        let open = session()
        await loader.load { open }
        var tries = 0
        await loader.load({ throw Offline() }, tryAgain: { tries += 1 })
        #expect(open.barItem == nil)
        // A retry that fails again does not restart the wait.
        await loader.load({ throw Offline() }, tryAgain: { tries += 10 })

        #expect(await eventually { loader.isStale })
        #expect(open.unavailableTitle == MacConversationLoader.staleTitle)
        #expect(open.barItem == .unavailable(reason: MacConversationLoader.staleReason, retrying: false))
        open.retryConnecting()
        // The newest load's Try Again is the one on the bar.
        #expect(tries == 10)

        // Back: the marks go, and the next drop waits the bound again.
        await loader.load { open }
        #expect(!loader.isStale)
        #expect(open.barItem == nil)
        await loader.load({ throw Offline() }, tryAgain: {})
        #expect(open.barItem == nil)
    }

    @Test func aLiveSessionInsideTheBoundCancelsTheMark() async {
        let loader = MacConversationLoader(quiet: .milliseconds(40))
        let open = session()
        await loader.load { open }
        await loader.load({ throw Offline() }, tryAgain: {})
        let live = session()
        await loader.load { live }
        try? await Task.sleep(for: .milliseconds(120))
        #expect(!loader.isStale)
        #expect(open.barItem == nil)
        #expect(live.barItem == nil)
    }

    @Test func theHeaderSaysConnectingOnlyPastTheQuietBound() async {
        // The conversation header's "Connecting…" line (ConversationViewController) follows this.
        let quiet = ConversationStore(backend: ChiefOfflineBackend())
        quiet.start()
        defer { quiet.stop() }
        #expect(await eventually { quiet.connection == .reconnecting })
        #expect(!quiet.connectionNoticeDue)

        let long = ConversationStore(backend: ChiefOfflineBackend())
        long.connectionQuietDelay = .milliseconds(30)
        long.start()
        defer { long.stop() }
        #expect(await eventually { long.connectionNoticeDue })
        #expect(!quiet.connectionNoticeDue)
    }

    @Test func theKeptConversationOpensWithNoBarWhileItsChannelOpens() {
        // It said "Connecting to your Mac…" over the kept messages on every open.
        let feed = MacHomeFeed(rowsCache: nil, transcripts: nil, accountID: { nil })
        let route = MacConversationRoute(conversationID: "c-quiet", chief: nil, title: "Quiet")
        let kept = feed.keptSession(for: route, orEmpty: true)
        #expect(kept != nil)
        #expect(kept?.barItem == nil)
    }
}
