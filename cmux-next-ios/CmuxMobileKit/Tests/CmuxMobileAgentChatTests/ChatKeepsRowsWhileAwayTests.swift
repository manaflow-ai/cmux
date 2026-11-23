import CmuxMobileDesign
import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Leo, 2026-11-12, on LTE: "wack reconnection state / just show the cache".
/// A chat away from its Mac keeps its rows on screen, readable, and says so in
/// one quiet line by the composer only after the outage lasted 10 s.
@MainActor
@Suite struct ChatKeepsRowsWhileAwayTests {
    private func makeStore(delay: Duration = QuietStatusGate.threshold) -> AgentChatStore {
        let store = AgentChatStore(source: PromptResendTests.Recorder(), quietStatus: QuietStatusGate(delay: delay))
        store.apply(.userMessage(text: "Read this", promptId: "p", turnId: "t", attachments: [], at: Date()))
        store.apply(.turnResult(turnId: "t", status: .completed, errorText: nil, at: Date()))
        return store
    }

    @Test func aDroppedLinkKeepsTheRowsAndSaysNothingAtFirst() {
        let store = makeStore()
        let turns = store.turns
        // AcpmuxSessionSource.linkDown: disconnected, then catching up.
        store.apply(.status(.disconnected))
        store.apply(.historyLoading(true))
        #expect(store.turns == turns, "the rows stay while the link is down")
        #expect(store.hasTurns)
        #expect(!store.isNewChat)
        #expect(store.connectionLine == nil, "nothing for the first 10 s")
    }

    @Test func theQuietLineAppearsAfterTheThresholdAndGoesWhenBack() async throws {
        let store = makeStore(delay: .milliseconds(60))
        store.apply(.status(.disconnected))
        store.apply(.historyLoading(true))
        #expect(store.connectionLine == nil)
        for _ in 0..<200 where store.connectionLine == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.connectionLine == "Connecting to m…")
        store.apply(.status(.idle))
        // Leo, 2026-11-23: a catch-up on a live link needs nothing of the person.
        #expect(store.connectionLine == nil, "the link is up: a catch-up says nothing")
        store.apply(.historyLoading(false))
        #expect(store.connectionLine == nil)
        #expect(!store.quietStatus.isShown)
    }

    /// Leo, 2026-11-23 17:14Z, on "Connecting" over "reconnecting to the Mac" by the composer
    /// of a live turn: "this toast is stupid. because it's false now". A slow catch-up on a
    /// live link never brings the quiet gate up, and only one indicator shows at a time.
    @Test func aSlowCatchUpOnALiveLinkSaysNothing() async throws {
        let store = makeStore(delay: .milliseconds(30))
        store.apply(.historyLoading(true))
        try await Task.sleep(for: .milliseconds(150))
        #expect(store.connectionLine == nil)
        #expect(!store.quietStatus.isShown, "only the link being down brings the gate up")
    }

    @Test func aNoticeTakesTheChipsPlace() async throws {
        let store = makeStore(delay: .milliseconds(30))
        store.apply(.status(.disconnected))
        for _ in 0..<200 where store.connectionLine == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.connectionLine == "Connecting to m…")
        store.apply(.clientError("Can't reach your Mac right now."))
        #expect(store.connectionLine == nil, "one indicator at a time: never two stacked chips")
        store.clientError = nil
        #expect(store.connectionLine == "Connecting to m…")
    }

    /// A chat opened from its kept rows while its Mac is out of reach (the source was made
    /// with the hub down, so no `.disconnected` reached it): past the bound it says
    /// Connecting, since the person may need to wake the Mac (cmux#52533 review).
    @Test func keptRowsFromAMacOutOfReachSayConnecting() {
        final class Away: AgentSessionSource {
            let summary = AgentSessionSummary(id: "t", name: "Fix", harness: "codex", agentName: "Codex", cwd: "~/p",
                                              workspaceTitle: "w", macName: "Mac")
            var isOffline: Bool { true }
            var loadsHistory: Bool { true }
            func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
            func send(_ intent: AgentClientIntent) {}
        }
        let store = AgentChatStore(source: Away(), quietStatus: QuietStatusGate(delay: .zero))
        store.apply(.userMessage(text: "Read this", promptId: "p", turnId: "t", attachments: [], at: Date()))
        store.apply(.turnResult(turnId: "t", status: .completed, errorText: nil, at: Date()))
        #expect(store.summary.status != .disconnected)
        #expect(store.connectionLine == "Connecting to Mac…")
    }

    @Test func aCatchUpNoticeGoesWhenTheCatchUpFinishes() {
        let store = makeStore()
        store.apply(.historyLoading(true))
        store.apply(.catchUpFailed("Can't reach your Mac right now."))
        #expect(store.clientError != nil)
        store.apply(.historyLoading(false))
        #expect(store.clientError == nil, "the catch-up finished: the notice is no longer true")
        // Another call's notice, even one said while a catch-up runs, stays until dismissed.
        store.apply(.historyLoading(true))
        store.apply(.clientError("Approve it on the Mac."))
        store.apply(.historyLoading(false))
        #expect(store.clientError == "Approve it on the Mac.")
    }

    @Test func aBlipShorterThanTheThresholdNeverShowsALine() async throws {
        let store = makeStore(delay: .milliseconds(150))
        store.apply(.status(.disconnected))
        try await Task.sleep(for: .milliseconds(30))
        store.apply(.status(.idle))
        try await Task.sleep(for: .milliseconds(250))
        #expect(store.connectionLine == nil)
        #expect(!store.quietStatus.isShown)
    }
}
