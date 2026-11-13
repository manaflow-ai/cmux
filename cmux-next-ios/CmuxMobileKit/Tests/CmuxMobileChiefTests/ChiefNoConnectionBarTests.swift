import Foundation
import Testing
@testable import CmuxMobileChief

/// Aziz 2026-11-12: "get rid of this banner in chief, dont use this UX element whatsoever".
/// Chief's connection state ("Not connected to your Mac", "Connecting to your Mac…",
/// "Chief isn't available") draws no bar over the conversation; the outbox keeps its own Retry.
@MainActor
@Suite struct ChiefNoConnectionBarTests {
    @Test func aDroppedLinkDrawsNoBar() {
        let session = ChiefSession(backend: ChiefOfflineBackend(reason: "x"), outbox: ChiefOutbox(file: nil))
        defer { session.store.stop() }
        MacConversationLoader.markStale(session, tryAgain: {})
        // The state is still known (it hides the endless first-load spinner) ...
        guard case .unavailable? = session.barItem else {
            Issue.record("expected the unavailable state, got \(String(describing: session.barItem))")
            return
        }
        // ... but nothing is drawn for it.
        #expect(ChiefQuestionBar.displayed(session.barItem) == nil)
    }

    @Test func otherBarsStillDraw() {
        let away = ChiefBarItem.macAway(reason: "Your Mac is offline.")
        #expect(ChiefQuestionBar.displayed(away) == away)
        #expect(ChiefQuestionBar.displayed(nil) == nil)
    }
}
