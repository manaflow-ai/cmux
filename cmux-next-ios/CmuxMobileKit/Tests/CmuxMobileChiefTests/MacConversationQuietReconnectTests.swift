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

    @Test func theKeptConversationOpensWithNoBarWhileItsChannelOpens() {
        // It said "Connecting to your Mac…" over the kept messages on every open.
        let feed = MacHomeFeed(rowsCache: nil, transcripts: nil, accountID: { nil })
        let route = MacConversationRoute(conversationID: "c-quiet", chief: nil, title: "Quiet")
        let kept = feed.keptSession(for: route, orEmpty: true)
        #expect(kept != nil)
        #expect(kept?.barItem == nil)
    }
}
