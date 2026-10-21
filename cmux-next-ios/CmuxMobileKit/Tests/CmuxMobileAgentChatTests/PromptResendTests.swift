import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// Live recheck (2026-10-20): after a link drop, a prompt the Mac already ran came back into
/// the composer, and Send would have run it twice. A prompt keeps one id across a resend
/// (acpmux runs each `promptId` once), and a returned draft goes away once the Mac shows it ran.
@MainActor
@Suite struct PromptResendTests {
    final class Recorder: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "codex", agentName: "Codex", cwd: "~", workspaceTitle: "w", macName: "m")
        var sent: [AgentClientIntent] = []
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) { sent.append(intent) }
    }

    static func prompt(_ intent: AgentClientIntent?) -> (text: String, id: String, resend: Bool)? {
        guard case .prompt(let text, _, _, let id, let resend)? = intent else { return nil }
        return (text, id, resend)
    }

    @Test func aReturnedPromptSentAgainKeepsItsID() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let first = try #require(Self.prompt(source.sent.last))
        #expect(!first.resend)
        // The link dropped before the reply: the draft comes back with its id.
        store.apply(.promptNotSent(text: "run the tests", attachments: [], promptID: first.id, reason: "link down"))
        #expect(store.returnedDraft?.promptID == first.id)
        store.returnedDraft = nil // the composer took it
        store.send(prompt: "run the tests")
        let again = try #require(Self.prompt(source.sent.last))
        #expect(again.id == first.id)
        #expect(again.resend)
        // A new prompt gets a new id.
        store.send(prompt: "something else")
        #expect(Self.prompt(source.sent.last)?.id != first.id)
    }

    @Test func anEditedDraftIsANewPrompt() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let first = try #require(Self.prompt(source.sent.last))
        store.apply(.promptNotSent(text: "run the tests", attachments: [], promptID: first.id, reason: "link down"))
        store.returnedDraft = nil
        store.send(prompt: "run the unit tests")
        #expect(Self.prompt(source.sent.last)?.id != first.id)
    }

    @Test func aDraftTheMacRanIsWithdrawn() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let first = try #require(Self.prompt(source.sent.last))
        store.apply(.promptNotSent(text: "run the tests", attachments: [], promptID: first.id, reason: "link down"))
        store.returnedDraft = nil
        // The replayed transcript shows the Mac ran it.
        store.apply(.userMessage(text: "run the tests", promptId: first.id, turnId: "t1", attachments: [], at: Date()))
        #expect(store.withdrawnDraft?.text == "run the tests")
        // Nothing is left to resend under that id.
        store.send(prompt: "run the tests")
        let again = try #require(Self.prompt(source.sent.last))
        #expect(again.id != first.id)
        #expect(!again.resend)
    }

    /// Review: the reply was lost after the transcript already showed the prompt: nothing comes back.
    @Test func aPromptSeenRunningNeverComesBack() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "run the tests")
        let first = try #require(Self.prompt(source.sent.last))
        store.apply(.userMessage(text: "run the tests", promptId: first.id, turnId: "t1", attachments: [], at: Date()))
        store.apply(.promptNotSent(text: "run the tests", attachments: [], promptID: first.id, reason: "link down"))
        #expect(store.returnedDraft == nil)
        store.send(prompt: "run the tests")
        #expect(Self.prompt(source.sent.last)?.id != first.id)
    }

    /// Review: other attachments are another prompt; a withdrawal takes the attachments too.
    @Test func attachmentsCountAndLeaveWithTheDraft() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        let photo = AgentAttachment(kind: .file, name: "a.txt")
        store.send(prompt: "look", attachments: [photo])
        let first = try #require(Self.prompt(source.sent.last))
        store.apply(.promptNotSent(text: "look", attachments: [photo], promptID: first.id, reason: "link down"))
        store.returnedDraft = nil
        store.send(prompt: "look", attachments: [])
        #expect(Self.prompt(source.sent.last)?.id != first.id)

        store.send(prompt: "look again", attachments: [photo])
        let second = try #require(Self.prompt(source.sent.last))
        store.apply(.promptNotSent(text: "look again", attachments: [photo], promptID: second.id, reason: "link down"))
        store.returnedDraft = nil
        store.apply(.queued(text: "look again", promptId: second.id, position: 0))
        #expect(store.withdrawnDraft?.attachments == [photo])
    }
}

