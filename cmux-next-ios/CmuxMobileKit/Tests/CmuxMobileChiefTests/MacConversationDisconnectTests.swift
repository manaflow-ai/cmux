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
}
