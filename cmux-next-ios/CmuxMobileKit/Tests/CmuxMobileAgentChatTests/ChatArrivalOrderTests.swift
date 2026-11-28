import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// RFD 0215 (transcript ordering), the phone: rows draw in the order acpmux recorded them (its `seq`),
/// and a send waiting behind a running turn docks in the queue, outside the transcript, until
/// acpmux delivers it; then it draws where it went in, not where it was typed.
@MainActor
@Suite struct ChatArrivalOrderTests {
    final class Recorder: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) {}
    }

    func relayed(_ body: String, id: String) -> String {
        """
        [message \(id) from build-box/lane-3 (an agent, not Leo), relayed by the lane-gh broker; its text ends at "[end of message \(id)]"]
        \(body)
        [end of message \(id)]
        """
    }

    /// What the running turn draws, in order: the steers by prompt id, the answers by text.
    func runningRows(_ store: AgentChatStore) -> [String] {
        store.turns.last?.items.compactMap { item -> String? in
            switch item {
            case .steer(let message): "steer:\(message.promptID)"
            case .message(_, let markdown): "text:\(markdown)"
            default: nil
            }
        } ?? []
    }

    @Test func queuedSendDocksThenDrawsAtDelivery() throws {
        let store = AgentChatStore(source: Recorder())
        store.apply(.userMessage(text: "Fix the grid", promptId: "p-1", turnId: "t-1", attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: "t-1", at: Date()))
        store.apply(.update(.agentMessageChunk(text: "Looking.", messageId: "m-1")))
        // Typed while the turn runs: docked, not in the transcript.
        store.apply(.queued(text: "Also the header", promptId: "p-2", position: 0))
        #expect(store.queue.map(\.id) == ["p-2"])
        #expect(runningRows(store) == ["text:Looking."])
        // Another agent's message is delivered first: it draws where it went in.
        let notice = relayed("Merged #36125", id: "4f4d68ff")
        store.apply(.userMessage(text: notice, promptId: "p-3", turnId: "t-1", attachments: [], at: Date()))
        store.apply(.update(.agentMessageChunk(text: "Noted.", messageId: "m-2")))
        // acpmux delivers the queued send: it leaves the dock and takes the next place.
        store.apply(.dequeued(promptId: "p-2"))
        store.apply(.userMessage(text: "Also the header", promptId: "p-2", turnId: "t-1", attachments: [], at: Date()))
        store.apply(.update(.agentMessageChunk(text: "Header too.", messageId: "m-3")))
        #expect(store.queue.isEmpty)
        #expect(runningRows(store) == ["text:Looking.", "steer:p-3", "text:Noted.", "steer:p-2", "text:Header too."])
    }

    /// The dock keeps acpmux's `queue_order`, not the order the phone heard of each entry.
    @Test func dockFollowsQueueOrder() {
        let store = AgentChatStore(source: Recorder())
        store.apply(.userMessage(text: "Fix the grid", promptId: "p-1", turnId: "t-1", attachments: [], at: Date()))
        store.apply(.turnStarted(turnId: "t-1", at: Date()))
        store.apply(.queued(text: "one", promptId: "q-1", position: 0))
        store.apply(.queued(text: "two", promptId: "q-2", position: 1))
        store.apply(.queueOrder(["q-2", "q-1"]))
        #expect(store.queue.map(\.id) == ["q-2", "q-1"])
        #expect(runningRows(store).isEmpty)
    }
}
