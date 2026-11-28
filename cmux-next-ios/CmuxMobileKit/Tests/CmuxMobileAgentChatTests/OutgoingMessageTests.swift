import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// A message shows the moment Send is tapped (with files, its upload's progress) until the
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

    /// A text message shows at once, before the Mac answers (Leo, 2026-11-24: "i think we can
    /// maybe be more optimistic sometimes. it is a bit slow on ios."), and goes at the echo.
    @Test func aTextOnlyMessageShowsAtOnceUntilTheEcho() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "hi")
        let id = try sentID(source)
        #expect(store.outgoing.map(\.id) == [id])
        #expect(store.outgoing.first?.isTextOnly == true)
        #expect(store.outgoing.first?.text == "hi")

        store.apply(.userMessage(text: "hi", promptId: id, turnId: "t1", attachments: [], at: Date()))
        #expect(store.outgoing.isEmpty)
        #expect(store.turns.count == 1)
    }

    /// Sent while a turn runs, it waits in the queue: drawn there, not also as a pending bubble.
    @Test func aQueuedTextMessageMovesToTheQueue() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "next")
        let id = try sentID(source)
        store.apply(.queued(text: "next", promptId: id, position: 0))
        #expect(store.outgoing.isEmpty)
        #expect(store.queue.map(\.id) == [id])
    }

    /// A send that fails comes back to the composer with its reason: that is the retry.
    @Test func aFailedTextMessageComesBackToTheComposer() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "hi")
        let id = try sentID(source)
        store.apply(.promptNotSent(text: "hi", attachments: [], promptID: id, reason: "Not sent: the Mac is offline."))
        #expect(store.outgoing.isEmpty)
        #expect(store.returnedDraft?.text == "hi")
        #expect(store.clientError == "Not sent: the Mac is offline.")
        // Sent again, it keeps its id (acpmux runs it once) and shows at once again.
        store.send(prompt: "hi")
        #expect(try sentID(source) == id)
        #expect(store.outgoing.map(\.id) == [id])
    }
    /// Leo 2026-11-24: "i also couldnt cancel out of the send. i need to be able to do that
    /// otherwise i cant edit or anything to retry or delete and remove." A text message waiting
    /// on its way gets a row with its exits; Delete drops it, Stop brings it back to edit.
    @Test func aWaitingTextMessageHasARowToStopRetryOrDelete() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "hi")
        let id = try sentID(source)
        store.apply(.pendingSends([AgentPendingSend(promptID: id, text: "hi", waiting: true, canSendNow: true, stopping: false)]))
        #expect(store.outgoing.map(\.id) == [id])
        #expect(store.outgoing.first?.waiting == true)
        #expect(store.outgoing.first?.canSendNow == true)

        store.retrySend(promptID: id)
        #expect(source.sent.last == .retrySend(promptID: id))

        store.cancelSend(promptID: id)
        #expect(source.sent.last == .cancelSend(promptID: id))
        store.apply(.pendingSends([AgentPendingSend(promptID: id, text: "hi", waiting: false, canSendNow: false, stopping: true)]))
        #expect(store.outgoing.first?.stopping == true)
        store.apply(.promptNotSent(text: "hi", attachments: [], promptID: id, reason: "Not sent: you stopped it."))
        store.apply(.pendingSends([]))
        #expect(store.outgoing.isEmpty)

        store.send(prompt: "again")
        let second = try sentID(source)
        store.apply(.pendingSends([AgentPendingSend(promptID: second, text: "again", waiting: true, canSendNow: false, stopping: false)]))
        store.deleteSend(promptID: second)
        #expect(source.sent.last == .deleteSend(promptID: second))
        #expect(store.outgoing.isEmpty)
        // A late row or its return does not bring a deleted message back.
        store.apply(.pendingSends([AgentPendingSend(promptID: second, text: "again", waiting: true, canSendNow: false, stopping: false)]))
        #expect(store.outgoing.isEmpty)
    }

    /// The outbox lists a text message only while it waits: the bubble shown at the tap stays
    /// through the outbox's rows (quiet, then a row with exits, then quiet again) until the echo.
    @Test func aTextMessageStaysFromTheTapThroughTheOutboxRowsUntilItsEcho() throws {
        let source = Recorder()
        let store = AgentChatStore(source: source)
        store.send(prompt: "hi")
        let id = try sentID(source)
        store.apply(.pendingSends([]))
        #expect(store.outgoing.map(\.id) == [id])
        #expect(store.outgoing.first?.isQuietPending == true)

        store.apply(.pendingSends([AgentPendingSend(promptID: id, text: "hi", waiting: true, canSendNow: true, stopping: false)]))
        #expect(store.outgoing.first?.isQuietPending == false)

        store.apply(.pendingSends([]))
        #expect(store.outgoing.map(\.id) == [id])
        #expect(store.outgoing.first?.isQuietPending == true)

        store.apply(.userMessage(text: "hi", promptId: id, turnId: "t1", attachments: [], at: Date()))
        #expect(store.outgoing.isEmpty)
    }
}
