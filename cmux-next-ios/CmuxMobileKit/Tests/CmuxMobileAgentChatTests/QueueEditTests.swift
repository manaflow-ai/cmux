import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// The agent pane's queue actions on the phone: Edit queued prompt, Send now,
/// Move up / Move down, with the events acpmux sends back.
@MainActor
@Suite struct QueueEditTests {
    final class Recorder: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        var sent: [AgentClientIntent] = []
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) { sent.append(intent) }
    }

    @Test func intentsAndEvents() {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.apply(.queued(text: "one", promptId: "p1", position: 0))
        store.apply(.queued(text: "two", promptId: "p2", position: 1))
        store.editQueued("p1", text: "  one, edited ")
        store.editQueued("p1", text: "   ")
        store.sendQueuedNow("p2")
        store.moveQueued("p2", by: -1)
        store.moveQueued("p1", by: -1)
        #expect(source.sent == [.editQueued(promptId: "p1", text: "one, edited"), .sendQueuedNow(promptId: "p2"),
                                .moveQueued(promptId: "p2", index: 0)])
        store.apply(.queueUpdated(promptId: "p1", text: "one, edited"))
        store.apply(.queueOrder(["p2", "p1"]))
        #expect(store.queue.map(\.text) == ["two", "one, edited"])
    }
}
