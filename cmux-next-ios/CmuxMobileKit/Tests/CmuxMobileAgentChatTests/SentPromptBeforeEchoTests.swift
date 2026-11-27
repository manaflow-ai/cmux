import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Leo, 2026-11-15: "Tho the animation for sending messages is kinda ass". Before #43956 the
/// composer cleared on tap and the chat drew nothing until the Mac's record of the prompt came
/// back a round trip later. This test uses only API that existed before the change, so it runs
/// against the base too: there it fails (no turn until the echo), here it passes.
@MainActor
@Suite struct SentPromptBeforeEchoTests {
    final class Recorder: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        var sent: [AgentClientIntent] = []
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) { sent.append(intent) }
    }

    @Test func aPromptIntoAnIdleChatIsDrawnBeforeTheMacEchoesIt() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        #expect(source.sent.count == 1, "the prompt went to the Mac")
        #expect(store.turns.count == 1, "the sent prompt is a turn the moment Send is tapped")
        #expect(store.turns.last?.prompt == "run the tests")
    }

    @Test func theMacsEchoDoesNotDoubleTheShownPrompt() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "go")
        guard case .prompt(_, _, _, let id, _)? = source.sent.last else {
            Issue.record("no prompt intent sent")
            return
        }
        store.apply(.userMessage(text: "go", promptId: id, turnId: "t1", attachments: [], at: Date()))
        #expect(store.turns.map(\.id) == ["t1"], "one turn, the Mac's")
        #expect(store.turns.last?.prompt == "go")
    }
}
