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
        /// A recorded image's bytes, as acpmux returns them (nil: unreadable).
        var recorded: [String: Data] = [:]
        func attachmentData(_ attachment: AgentAttachment) async -> Data? {
            attachment.recordedImageID.flatMap { recorded[$0] }
        }
    }

    /// PNG signature plus padding: an image an agent accepts.
    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0])
    static let image = AgentAttachment(id: "img", kind: .image, name: "shot.png", data: png)

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
        guard case .retryWithModel(let model, let text, _, let promptID)? = source.sent.last else {
            Issue.record("expected a retry with another model, got \(String(describing: source.sent.last))")
            return
        }
        #expect(model == "sonnet" && text == "fix the build" && !promptID.isEmpty)
        // The model the chat runs: a plain Retry.
        store.retry(turn("fix the build"), model: "opus")
        #expect(PromptResendTests.prompt(source.sent.last)?.text == "fix the build")
    }

    private func turn(_ prompt: String, attachments: [AgentAttachment]) -> AgentTurn {
        AgentTurn(id: "t1", prompt: prompt, attachments: attachments, promptAt: Date())
    }

    private func sentAttachments(_ intent: AgentClientIntent?) -> [AgentAttachment]? {
        switch intent {
        case .prompt(_, let attachments, _, _, _)?: attachments
        case .retryWithModel(_, _, let attachments, _)?: attachments
        default: nil
        }
    }

    /// HQ#5400: a finished turn's Retry sends what it attached, an image-only one included.
    @Test func retryKeepsTheTurnsAttachments() {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.retry(turn("", attachments: [Self.image]))
        #expect(sentAttachments(source.sent.last)?.map(\.id) == ["img"])
        store.retry(turn("what's this?", attachments: [Self.image]))
        #expect(PromptResendTests.prompt(source.sent.last)?.text == "what's this?")
        #expect(sentAttachments(source.sent.last)?.map(\.id) == ["img"])
    }

    /// HQ#5400: Retry with another model carries the attachments, and an image-only turn is
    /// not a no-op.
    @Test func anotherModelKeepsTheTurnsAttachments() {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.apply(.modelsAvailable([ACPModelInfo(id: "opus", name: "Opus"), ACPModelInfo(id: "sonnet", name: "Sonnet")], current: "opus"))
        store.retry(turn("", attachments: [Self.image]), model: "sonnet")
        guard case .retryWithModel(let model, let text, let attachments, _)? = source.sent.last else {
            Issue.record("expected a retry with another model, got \(String(describing: source.sent.last))")
            return
        }
        #expect(model == "sonnet" && text.isEmpty && attachments.map(\.id) == ["img"])
        // The model the chat runs: a plain Retry, attachments included.
        store.retry(turn("look again", attachments: [Self.image]), model: "opus")
        #expect(PromptResendTests.prompt(source.sent.last)?.text == "look again")
        #expect(sentAttachments(source.sent.last)?.map(\.id) == ["img"])
    }

    /// An image only the Mac's record holds is read back before the retry goes.
    @Test func aRecordedImageIsReadBackBeforeTheRetry() async {
        let source = Recorder()
        source.recorded["abc"] = Self.png
        let store = AgentChatStore(source: source)
        let recorded = AgentAttachment(id: AgentAttachment.recordedImagePrefix + "abc", kind: .image, name: "shot.png")
        store.retry(turn("", attachments: [recorded]))
        for _ in 0..<50 where source.sent.isEmpty { await Task.yield() }
        let sent = sentAttachments(source.sent.last)
        #expect(sent?.map(\.id) == [recorded.id])
        #expect(sent?.first?.data == Self.png)
    }
}
