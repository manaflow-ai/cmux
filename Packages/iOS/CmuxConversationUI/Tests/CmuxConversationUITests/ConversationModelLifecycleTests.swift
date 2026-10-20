import CmuxConversation
@testable import CmuxConversationUI
import Foundation
import Testing

@MainActor
@Suite struct ConversationModelLifecycleTests {
    @Test func lateRejectedCommandRestoresOnlyItsOriginalTaskDraft() async throws {
        let client = LifecycleConversationClient()
        let model = ConversationModel(client: client)
        model.selectSession(id: "task-a")
        try await requireEventually { model.connectionState == .connected }
        model.updateDraft("instruction for task A")
        model.submitDraft()
        try await requireEventually { await client.hasCommand }
        model.selectSession(id: "task-b")
        try await requireEventually { model.connectionState == .connected }
        await client.finishCommand(state: .rejected)
        try await requireEventually { !model.isSubmitting }
        #expect(model.draft.isEmpty)
        #expect(model.errorMessage == nil)
        model.selectSession(id: "task-a")
        #expect(model.draft == "instruction for task A")
        model.selectSession(id: nil)
        await client.finishStreams()
    }

    @Test func rejectedQueueCancellationDoesNotCopyTheStillQueuedPrompt() async throws {
        let client = LifecycleConversationClient()
        let model = ConversationModel(client: client)
        model.selectSession(id: "task-a")
        try await requireEventually { model.connectionState == .connected }
        model.cancelQueue(.init(id: "queue-a", commandID: "queue-command", text: "still queued", position: 0))
        try await requireEventually { await client.hasCommand }
        await client.finishCommand(state: .rejected)
        try await requireEventually { !model.isSubmitting }
        #expect(model.draft.isEmpty)
        model.selectSession(id: nil)
        await client.finishStreams()
    }

    @Test func activeStreamDoesNotRetainDiscardedModel() async throws {
        let client = LifecycleConversationClient()
        var model: ConversationModel? = ConversationModel(client: client)
        weak var weakModel = model
        model?.selectSession(id: "task-a")
        try await requireEventually { model?.connectionState == .connected }
        model = nil
        let released = await eventually { weakModel == nil }
        #expect(released)
        await client.finishStreams()
    }

    private func requireEventually(_ predicate: @MainActor () async -> Bool) async throws {
        let result = await eventually(predicate)
        try #require(result)
    }

    private func eventually(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            if await predicate() { return true }
            await Task.yield()
        } while ContinuousClock.now < deadline
        return false
    }
}

private actor LifecycleConversationClient: ConversationClient {
    private var continuations: [AsyncThrowingStream<ConversationEvent, any Error>.Continuation] = []
    private var command: ConversationCommandEnvelope?
    private var commandWaiter: CheckedContinuation<ConversationReceipt, Never>?
    var hasCommand: Bool { commandWaiter != nil }

    func listSessions() async throws -> [ConversationSession] { [] }
    func createSession(_ request: ConversationCreateRequest) async throws -> ConversationSession {
        ConversationSession(id: "created", provider: request.provider, title: "Task", workspaceID: request.workspaceID, directory: request.directory)
    }
    func snapshot(sessionID: ConversationID) async throws -> ConversationSnapshot {
        let session = ConversationSession(id: sessionID, provider: .codex, title: "Task", workspaceID: "workspace", directory: "/tmp", generation: "generation")
        return ConversationSnapshot(session: session, cursor: 0, generation: session.generation, capabilities: .init(protocolVersion: "test", supportsResume: true))
    }
    func replay(sessionID: ConversationID, after: ConversationCursor) async throws -> [ConversationEvent] { [] }
    func events(sessionID: ConversationID, after: ConversationCursor) async -> AsyncThrowingStream<ConversationEvent, any Error> {
        let pair = AsyncThrowingStream<ConversationEvent, any Error>.makeStream()
        continuations.append(pair.continuation)
        return pair.stream
    }
    func execute(_ command: ConversationCommandEnvelope) async throws -> ConversationReceipt {
        self.command = command
        return await withCheckedContinuation { commandWaiter = $0 }
    }
    func receipt(_ query: ConversationReceiptQuery) async throws -> ConversationReceipt? { nil }
    func receipt(sessionID: ConversationID, commandID: ConversationCommandID) async throws -> ConversationReceipt? { nil }
    func finishCommand(state: ConversationReceiptState) {
        guard let command, let waiter = commandWaiter else { return }
        commandWaiter = nil
        waiter.resume(returning: ConversationReceipt(id: command.commandID, sessionID: command.sessionID, state: state, reason: "not applied", generation: "generation"))
    }
    func finishStreams() {
        for continuation in continuations { continuation.finish() }
        continuations.removeAll()
    }
}
