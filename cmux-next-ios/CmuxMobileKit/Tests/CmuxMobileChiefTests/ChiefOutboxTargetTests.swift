import CmuxConversationCore
import Foundation
import Testing
@testable import CmuxMobileChief

/// A Mac Chief whose sends never come back (a link that died mid-send): the
/// rest of the conversation is the mock Chief's.
private final class StalledSendBackend: ConversationBackend, @unchecked Sendable {
    let inner = ChiefMockBackend(sleep: { _ in })
    func events() -> AsyncStream<ConversationBackendEvent> { inner.events() }
    func history(beforeSeq: Int?, limit: Int) async throws -> ConversationHistoryPage { try await inner.history(beforeSeq: beforeSeq, limit: limit) }
    func send(_ draft: ConversationOutgoingDraft) async throws -> ConversationMessage {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
    func react(messageID: String, reaction: ConversationReaction?) async throws -> ConversationMessage { try await inner.react(messageID: messageID, reaction: reaction) }
    func edit(messageID: String, text: String) async throws -> ConversationMessage { try await inner.edit(messageID: messageID, text: text) }
    func unsend(messageID: String) async throws -> ConversationMessage { try await inner.unsend(messageID: messageID) }
    func setTyping(_ isTyping: Bool) async { await inner.setTyping(isTyping) }
    func markRead(upToSeq: Int) async { await inner.markRead(upToSeq: upToSeq) }
    func uploadImage(_ data: Data, mimeType: String) async throws -> ConversationAttachment { try await inner.uploadImage(data, mimeType: mimeType) }
    func close() { inner.close() }
    func linkPreview(for url: URL) async throws -> ConversationLinkPreview? { nil }
    func votePoll(messageID: String, optionID: String, selected: Bool) async throws -> ConversationMessage {
        try await inner.votePoll(messageID: messageID, optionID: optionID, selected: selected)
    }
    func addPollOption(messageID: String, text: String) async throws -> ConversationMessage { try await inner.addPollOption(messageID: messageID, text: text) }
    func scheduledMessages() async throws -> [ConversationMessage] { [] }
    func scheduleSend(_ draft: ConversationOutgoingDraft, at date: Date) async throws -> ConversationMessage { try await inner.scheduleSend(draft, at: date) }
    func reschedule(scheduledID: String, to date: Date) async throws -> ConversationMessage { try await inner.reschedule(scheduledID: scheduledID, to: date) }
    func cancelScheduled(scheduledID: String) async throws { try await inner.cancelScheduled(scheduledID: scheduledID) }
    func sendScheduledNow(scheduledID: String) async throws -> ConversationMessage { try await inner.sendScheduledNow(scheduledID: scheduledID) }
}

/// QA 2026-10-27: Chief's outbox belongs to the Chief a message was written to.
@Suite @MainActor struct ChiefOutboxTargetTests {
    private func outboxFile() -> ChiefOutbox {
        ChiefOutbox(file: FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString).json"))
    }

    /// Written to Mac A's Chief while A is away; Mac B's Chief connects next.
    /// Before: B's Chief got A's message. Now it waits for A.
    @Test func aMessageForOneMacNeverGoesToAnotherMacsChief() async throws {
        let outbox = outboxFile()
        let session = ChiefSession(backend: ChiefOfflineBackend(), outbox: outbox)
        session.macID = "mac-A"
        session.send(ConversationComposeMessage(text: "for mac A only"))
        #expect(session.outbox.map(\.text) == ["for mac A only"])

        // Focus moves to Mac B; its Chief connects.
        session.macID = "mac-B"
        session.use(ChiefMockBackend(sleep: { _ in }))
        #expect(session.outbox.isEmpty)
        try await waitUntil("Mac B's Chief to connect") { session.isConnected }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!session.store.messages.contains { $0.text == "for mac A only" })

        // Back on Mac A: it goes out there.
        session.macID = "mac-A"
        session.use(ChiefMockBackend(sleep: { _ in }))
        try await waitUntil("the message to reach Mac A's Chief") {
            session.store.messages.contains { $0.text == "for mac A only" && $0.seq != nil }
        }
        #expect(session.outbox.isEmpty)
    }

    /// Review B1: the coordinator names Mac B (`macID`) before B's backend
    /// replaces Mac A's, which is still connected. A message parked for B
    /// must not go to A's Chief in that window, and A stays the target.
    @Test func namingTheNextMacFirstSendsNothingToTheCurrentOne() async throws {
        let outbox = outboxFile()
        outbox.save([ChiefOutbox.Waiting(message: ConversationComposeMessage(text: "parked for mac B"), target: "mac:mac-B")])
        let session = ChiefSession(backend: ChiefOfflineBackend(), outbox: outbox)
        session.macID = "mac-A"
        session.use(ChiefMockBackend(sleep: { _ in }))
        try await waitUntil("Mac A's Chief to connect") { session.isConnected && session.store.hasLoadedNewest }
        session.macID = "mac-B"
        #expect(session.outboxTarget == "mac:mac-A")
        // Mac A's store keeps changing meanwhile (a message of its own).
        session.send(ConversationComposeMessage(text: "for mac A"))
        try await waitUntil("A's own message to go out") { session.store.messages.contains { $0.text == "for mac A" && $0.seq != nil } }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!session.store.messages.contains { $0.text == "parked for mac B" })
        // B's backend arrives: now it is B's turn.
        session.use(ChiefMockBackend(sleep: { _ in }))
        try await waitUntil("the parked message to reach Mac B") {
            session.store.messages.contains { $0.text == "parked for mac B" && $0.seq != nil }
        }
    }

    /// The Mac link drops while a send is in flight: the backend is swapped
    /// for the offline one. Before: the row vanished with the old store. Now
    /// it waits in the outbox for the same Mac and goes out when it is back.
    @Test func aSendTheMacNeverConfirmedSurvivesTheLinkDropping() async throws {
        let outbox = outboxFile()
        let session = ChiefSession(backend: StalledSendBackend(), outbox: outbox)
        session.macID = "mac-A"
        try await waitUntil("Chief to connect") { session.isConnected && session.store.meID != nil }
        session.send(ConversationComposeMessage(text: "in flight when the link died"))
        try await waitUntil("the row to show as sending") {
            session.store.messages.contains { $0.text == "in flight when the link died" && $0.delivery == .sending }
        }
        session.use(ChiefOfflineBackend())
        #expect(session.outbox.map(\.text) == ["in flight when the link died"])

        session.use(ChiefMockBackend(sleep: { _ in }))
        try await waitUntil("the kept message to go out") {
            session.store.messages.contains { $0.text == "in flight when the link died" && $0.seq != nil }
        }
        #expect(session.outbox.isEmpty)
    }
}
