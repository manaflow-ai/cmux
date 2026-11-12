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
        #expect(store.connectionLine == "Updating…", "still catching up with the Mac")
        store.apply(.historyLoading(false))
        #expect(store.connectionLine == nil)
        #expect(!store.quietStatus.isShown)
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
