import Foundation
import Testing
@testable import CmuxHomeCore

/// Typing frames end with the connection (TypingLifetimeTests), but a Chief turn
/// still running keeps its dots: they come from its live run, which the store
/// reads again from the owner on reconnect.
@MainActor @Suite struct TypingAfterReconnectTests {
    let chief = ParticipantID("agent_chief")
    let conv = ConversationID("conv_a")

    private func running(_ store: HomeStore) {
        store.handle(.live(.snapshot(conversation: conv, runs: [
            HomeLiveRunSnapshot(author: chief, run: "run_1", steps: [],
                                activity: HomeLiveActivity(line: "Thinking", since: Date(timeIntervalSince1970: 0))),
        ])))
    }

    @Test func aRunningTurnKeepsItsDotsAcrossAReconnect() {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.handle(.connection(.online))
        running(store)
        store.handle(.typing(conv, chief, on: true))
        #expect(store.typists(in: conv) == [chief])

        store.handle(.connection(.offline(since: Date(timeIntervalSince1970: 1))))
        #expect(store.typing[conv] == nil)
        #expect(store.typists(in: conv) == [chief], "the run still runs: its dots stay")

        store.handle(.connection(.online))
        #expect(store.liveRequests.contains(conv), "reconnect asks the owner for its live runs again")
        #expect(store.typists(in: conv) == [chief])
    }

    @Test func aTurnThatEndedWhileOfflineLosesItsDots() {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.handle(.connection(.online))
        running(store)
        store.handle(.connection(.offline(since: Date(timeIntervalSince1970: 1))))
        store.handle(.connection(.online))
        // The owner's answer: nothing runs any more.
        store.handle(.live(.snapshot(conversation: conv, runs: [])))
        #expect(store.typists(in: conv).isEmpty)
    }

    @Test func noRunNoDots() {
        let store = HomeStore(source: MockHomeSource(options: .immediate))
        store.handle(.connection(.online))
        #expect(store.typists(in: conv).isEmpty)
    }
}
