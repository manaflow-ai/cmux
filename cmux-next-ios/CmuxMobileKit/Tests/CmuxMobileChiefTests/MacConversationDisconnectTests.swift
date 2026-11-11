import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// CMUX-30: when the Mac's link dropped, an open Mac conversation was replaced
/// by a full-screen "Couldn't load this conversation." that hid the transcript
/// and the composer. The conversation stays, marked as not live, with Try Again.
@MainActor
@Suite struct MacConversationDisconnectTests {
    struct Offline: Error {}

    private func session() -> ChiefSession {
        ChiefSession(backend: ChiefOfflineBackend(), outbox: ChiefOutbox(file: nil), clock: ImmediateClock())
    }

    @Test func aDroppedLinkKeepsTheOpenConversationOnScreen() async {
        let loader = MacConversationLoader()
        let open = session()
        await loader.load { open }
        #expect(loader.session === open)

        await loader.load { throw Offline() }

        // No full-screen failure: the conversation that was open still shows.
        #expect(!loader.failed)
        #expect(loader.session === open)
        guard case .unavailable? = open.barItem else {
            Issue.record("expected the conversation's own bar to say it isn't live, got \(String(describing: open.barItem))")
            return
        }
    }

    @Test func aFirstOpenWithNothingToShowStillFails() async {
        let loader = MacConversationLoader()
        await loader.load { throw Offline() }
        #expect(loader.failed)
        #expect(loader.session == nil)
    }
    @Test func theKeptConversationSaysItIsNotLiveAndOffersTryAgain() async {
        let loader = MacConversationLoader()
        let open = session()
        await loader.load { open }
        var tries = 0
        await loader.load({ throw Offline() }, tryAgain: { tries += 1 })

        #expect(loader.isStale)
        #expect(open.unavailableTitle == MacConversationLoader.staleTitle)
        #expect(open.barItem == .unavailable(reason: MacConversationLoader.staleReason, retrying: false))
        #expect(open.canRetryConnecting)
        open.retryConnecting()
        #expect(tries == 1)
        #expect(open.barItem == .unavailable(reason: MacConversationLoader.staleReason, retrying: true))
        // The try failed again: Try Again is offered again, the conversation still shows.
        await loader.load({ throw Offline() }, tryAgain: { tries += 1 })
        #expect(open.barItem == .unavailable(reason: MacConversationLoader.staleReason, retrying: false))
        #expect(loader.session === open)
    }

    @Test func reconnectingReplacesTheKeptConversationAndCarriesWhatWasWritten() async {
        let loader = MacConversationLoader()
        let open = session()
        await loader.load { open }
        await loader.load({ throw Offline() }, tryAgain: {})
        open.send(ConversationComposeMessage(text: "Run the tests again"), asksForAlerts: false)
        #expect(open.outbox.map(\.text) == ["Run the tests again"])

        let live = session()
        await loader.load { live }

        #expect(loader.session === live)
        #expect(!loader.isStale)
        #expect(!loader.failed)
        // Nothing written while the Mac was away is lost.
        #expect(live.outbox.map(\.text) == ["Run the tests again"])
        #expect(open.outbox.isEmpty)
        // The stale marks go with it.
        #expect(open.unavailableTitle == nil)
        #expect(live.unavailableTitle == nil)
        #expect(live.status == nil)
    }

    @Test func theSameSessionComingBackClearsItsStaleBar() async {
        let loader = MacConversationLoader()
        let open = session()
        await loader.load { open }
        await loader.load({ throw Offline() }, tryAgain: {})
        #expect(open.status != nil)
        await loader.load { open }
        #expect(!loader.isStale)
        #expect(open.status == nil)
        #expect(open.unavailableTitle == nil)
        #expect(!open.canRetryConnecting)
    }
}
