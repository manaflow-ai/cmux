import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Retry with another model (the Mac's turn menu, cx-ncc.62): the chat moves to the model,
/// then the prompt goes again; the model it runs retries as Retry does.
@MainActor
@Suite struct RetryWithModelTests {
    final class Recorder: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "m")
        var sent: [AgentClientIntent] = []
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) { sent.append(intent) }
    }

    private func turn(_ prompt: String) -> AgentTurn {
        AgentTurn(id: "t1", prompt: prompt, promptAt: Date())
    }

    @Test func offeredOnlyWithTwoModels() {
        let store = AgentChatStore(source: Recorder())
        store.apply(.modelsAvailable([ACPModelInfo(id: "opus", name: "Opus")], current: "opus"))
        #expect(store.retryModels.isEmpty)
        store.apply(.modelsAvailable([ACPModelInfo(id: "opus", name: "Opus"), ACPModelInfo(id: "sonnet", name: "Sonnet")], current: "opus"))
        #expect(store.retryModels.map(\.id) == ["opus", "sonnet"])
    }

    @Test func anotherModelMovesThenSends() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.apply(.modelsAvailable([ACPModelInfo(id: "opus", name: "Opus"), ACPModelInfo(id: "sonnet", name: "Sonnet")], current: "opus"))
        store.retry(turn("  fix the build "), model: "sonnet")
        guard case .retryWithModel(let model, let text, let promptID)? = source.sent.last else {
            Issue.record("expected a retry with another model, got \(String(describing: source.sent.last))")
            return
        }
        #expect(model == "sonnet" && text == "fix the build" && !promptID.isEmpty)
        // The model the chat runs: a plain Retry.
        store.retry(turn("fix the build"), model: "opus")
        #expect(PromptResendTests.prompt(source.sent.last)?.text == "fix the build")
    }
}
