import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// The queued row's X while the agent runs: an empty composer takes the prompt
/// back, and a draft in the composer is never replaced by it.
@MainActor
@Suite struct QueueTakeBackTests {
    final class Recorder: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        var sent: [AgentClientIntent] = []
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) { sent.append(intent) }
    }

    private func queuedA() -> (Recorder, AgentChatStore) {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.apply(.queued(text: "prompt A", promptId: "a", position: 0))
        return (source, store)
    }

    @Test func emptyComposerTakesThePromptBack() {
        let (source, store) = queuedA()
        #expect(store.takeBackQueued("a", draft: "") == "prompt A")
        #expect(source.sent == [.removeQueued(promptId: "a")])
    }

    @Test func whitespaceDraftCountsAsEmpty() {
        let (source, store) = queuedA()
        #expect(store.takeBackQueued("a", draft: "  \n\t ") == "prompt A")
        #expect(source.sent == [.removeQueued(promptId: "a")])
    }

    @Test func occupiedDraftIsNeverReplaced() {
        let (source, store) = queuedA()
        // Draft B stays: nothing comes back for the composer, and A stays queued.
        #expect(store.takeBackQueued("a", draft: "draft B") == nil)
        #expect(source.sent.isEmpty)
        #expect(store.queue.map(\.text) == ["prompt A"])
    }
}
