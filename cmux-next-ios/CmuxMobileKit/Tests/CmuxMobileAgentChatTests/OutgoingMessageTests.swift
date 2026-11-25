import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// A message with files shows the moment Send is tapped, with its upload's progress, until the
/// Mac echoes it or it comes back (Leo 2026-11-24: "it just blocked me endlessly on a send").
@MainActor
@Suite struct OutgoingMessageTests {
    final class Recorder: AgentSessionSource {
        let summary = AgentSessionSummary(id: "s", name: "S", harness: "claude", agentName: "Claude", cwd: "~", workspaceTitle: "w", macName: "Mac")
        var sent: [AgentClientIntent] = []
        func events() -> AsyncStream<AgentSessionEvent> { AsyncStream { _ in } }
        func send(_ intent: AgentClientIntent) { sent.append(intent) }
    }

    static let video = AgentAttachment(kind: .file, name: "clip.mov", byteCount: 100_000_000)

    func sentID(_ source: Recorder) throws -> String {
        guard case .prompt(_, _, _, let id, _)? = source.sent.last else { throw CancellationError() }
        return id
    }

    @Test func showsAtOnceWithProgressUntilTheMacEchoesIt() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "look at this", attachments: [Self.video])
        let id = try sentID(source)
        #expect(store.outgoing.map(\.id) == [id])
        #expect(store.outgoing.first?.text == "look at this")

        let half = AgentUploadProgress(name: "clip.mov", sent: 50_000_000, total: 100_000_000, phase: .sending, attempt: 1)
        store.apply(.promptUploading(promptID: id, half))
        #expect(store.outgoing.first?.progress == half)
        // A step that hops over late does not move the bar back.
        store.apply(.promptUploading(promptID: id, AgentUploadProgress(name: "clip.mov", sent: 10, total: 100_000_000, phase: .sending, attempt: 1)))
        #expect(store.outgoing.first?.progress == half)
        #expect(half.text(macName: "Mac").hasPrefix("Sending clip.mov · "))

        store.apply(.userMessage(text: "look at this", promptId: id, turnId: "t1", attachments: [Self.video], at: Date()))
        #expect(store.outgoing.isEmpty)
    }

    @Test func stopCancelsTheUploadAndTheMessageComesBack() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "", attachments: [Self.video])
        let id = try sentID(source)
        store.cancelSend(promptID: id)
        #expect(source.sent.last == .cancelSend(promptID: id))

        store.apply(.promptNotSent(text: "", attachments: [Self.video], promptID: id, reason: "Not sent: you stopped it."))
        #expect(store.outgoing.isEmpty)
        #expect(store.returnedDraft?.attachments == [Self.video])
    }

    @Test func aTextOnlyMessageShowsNoCard() {
        let store = AgentChatStore(source: Recorder())
        store.send(prompt: "hi")
        #expect(store.outgoing.isEmpty)
    }
}
