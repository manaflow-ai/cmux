import CmuxMobileDesign
import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Leo, 2026-11-12, on LTE: "wack reconnection state / just show the cache".
/// A chat away from its Mac keeps its rows on screen, readable, and says nothing about the
/// link (Leo 2026-11-22); one line by the composer only when a send truly failed.
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

    /// Leo, 2026-11-22: "i dont wanna see connecting to [machine]... with the spinner, i want it
    /// to just work." However long the link is down, the chat says nothing about it; only a
    /// message the Mac could not take says so, on that message.
    @Test func aLongOutageNeverShowsAConnectingLine() async throws {
        let store = makeStore(delay: .milliseconds(60))
        store.apply(.status(.disconnected))
        store.apply(.historyLoading(true))
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.connectionLine == nil, "no \"Connecting to m…\" past the threshold")
        store.apply(.status(.idle))
        #expect(store.connectionLine == nil, "catching up with the Mac says nothing: the kept rows show")
        store.apply(.historyLoading(false))
        #expect(store.connectionLine == nil)
        #expect(store.clientError == nil)
    }

    @Test func aMessageTheMacCouldNotTakeSaysSoOnceAndClearsWhenBack() {
        let store = makeStore()
        store.apply(.status(.disconnected))
        store.apply(.clientError(AgentChatStore.unreachableNotice))
        #expect(store.clientError == nil, "never a toast")
        #expect(store.connectionLine == "Couldn't reach m. Try again in a moment.")
        store.apply(.status(.idle))
        #expect(store.connectionLine == nil)
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
