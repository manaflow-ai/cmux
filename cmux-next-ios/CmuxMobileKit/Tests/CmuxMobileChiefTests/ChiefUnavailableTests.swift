import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// Full verify D2/D3 (2026-10-19): with the Mac's Chief refused, the
/// conversation spun forever and a sent message vanished. Chief says why it
/// is unavailable, offers Try Again, and keeps what the user wrote.
@MainActor
@Suite struct ChiefUnavailableTests {
    @Test func aRefusedChiefShowsWhyAndTryAgain() {
        let session = ChiefSession(backend: ChiefOfflineBackend(), clock: ImmediateClock())
        // Before the link says anything, nothing is shown (the link may still come up).
        #expect(session.barItem == nil)
        var retries = 0
        session.reconnect = { retries += 1 }
        session.status = "Chief isn't running on Studio."
        guard case .unavailable(let reason, let retrying)? = session.barItem else {
            Issue.record("expected the unavailable bar, got \(String(describing: session.barItem))")
            return
        }
        #expect(reason == "Chief isn't running on Studio.")
        #expect(!retrying)
        session.retryConnecting()
        #expect(retries == 1)
        #expect(session.barItem == .unavailable(reason: "Chief isn't running on Studio.", retrying: true))
        // A second tap while it tries does nothing.
        session.retryConnecting()
        #expect(retries == 1)
        // The try ended with the same refusal: Try Again is offered again.
        session.status = "Chief isn't running on Studio."
        #expect(session.barItem == .unavailable(reason: "Chief isn't running on Studio.", retrying: false))
    }

    /// No outbox (Aziz 2026-11-14): with Chief offline a send is refused and nothing is kept, so
    /// the caller can say "Not sent"; ``ChiefSession/sendKeepingDraft(_:asksForAlerts:)`` puts the text in Chief's composer.
    @Test func aSendWhileChiefIsOfflineIsRefusedAndKeptOnlyAsADraft() {
        let session = ChiefSession(backend: ChiefOfflineBackend(), clock: ImmediateClock())
        defer { session.store.stop() }
        #expect(!session.acceptsSendsNow)
        #expect(!session.send(ConversationComposeMessage(text: "Hello Chief")))
        #expect(session.store.messages.isEmpty)
        #expect(!session.needsYou)
        session.sendKeepingDraft(text: "Hello Chief")
        #expect(session.store.messages.isEmpty)
        // No Chief screen open: the next one puts it in its field.
        #expect(session.takeUnsentText() == "Hello Chief")
        #expect(session.takeUnsentText() == nil, "shown once")
    }

    @Test func withoutRefusalOrReconnectHookNoTryAgain() {
        let session = ChiefSession(backend: ChiefOfflineBackend(), clock: ImmediateClock())
        session.status = "No Mac"
        #expect(session.barItem == .unavailable(reason: "No Mac", retrying: false))
        // No hook: Try Again does nothing and never shows as trying.
        session.retryConnecting()
        #expect(session.barItem == .unavailable(reason: "No Mac", retrying: false))
        #expect(!session.canRetryConnecting)
    }
}
