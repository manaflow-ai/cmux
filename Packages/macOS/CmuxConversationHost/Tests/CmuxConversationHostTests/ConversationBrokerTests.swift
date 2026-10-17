import Foundation
import Testing
import CmuxConversation
@testable import CmuxConversationHost

@Suite struct ConversationBrokerTests {
    @Test func sameCommandIDDispatchesOnceAndPayloadConflictIsRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = BrokerFixture()
        let broker = try ConversationBroker(directory: root, adapters: [fixture.adapter])
        let session = try await broker.createSession(createRequest())
        let envelope = ConversationCommandEnvelope(commandID: "turn-command", sessionID: session.id, command: .startTurn(text: "one", model: nil, effort: nil))
        async let first = broker.execute(envelope)
        async let second = broker.execute(envelope)
        let receipts = try await [first, second]
        #expect(receipts[0].state == .applied)
        #expect(receipts[1].state == .applied)
        #expect(await fixture.connection.sendCount(for: .startTurn(text: "one", model: nil, effort: nil)) == 1)
        let conflict = try await broker.execute(ConversationCommandEnvelope(commandID: "turn-command", sessionID: session.id, command: .startTurn(text: "two", model: nil, effort: nil)))
        #expect(conflict.state == .rejected)
        #expect(await fixture.connection.sendCount(for: .startTurn(text: "two", model: nil, effort: nil)) == 0)
    }

    @Test func queuedCancellationRestoresDraftAndLateTurnCannotFinishNewTurn() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = BrokerFixture()
        let broker = try ConversationBroker(directory: root, adapters: [fixture.adapter])
        let session = try await broker.createSession(createRequest())
        await fixture.connection.emit(ConversationProviderEvent(kind: .turn, turnID: "old-turn", state: "running"))
        _ = try await waitForSnapshot(broker, sessionID: session.id) { $0.activeTurnID == "old-turn" }
        let queued = try await broker.execute(ConversationCommandEnvelope(commandID: "queue-command", sessionID: session.id, command: .queue(text: "restore me")))
        #expect(queued.state == .applied)
        let queuedSnapshot = try await broker.snapshot(sessionID: session.id)
        let item = try #require(queuedSnapshot.queued.first)
        let cancelled = try await broker.execute(ConversationCommandEnvelope(commandID: "cancel-command", sessionID: session.id, command: .cancelQueued(itemID: item.id)))
        #expect(cancelled.state == .applied)
        #expect(cancelled.draftText == "restore me")
        await fixture.connection.emit(ConversationProviderEvent(kind: .turn, turnID: "new-turn", state: "running"))
        _ = try await waitForSnapshot(broker, sessionID: session.id) { $0.activeTurnID == "new-turn" }
        await fixture.connection.emit(ConversationProviderEvent(kind: .turn, turnID: "old-turn", state: "completed"))
        let afterLateCompletion = try await waitForSnapshot(broker, sessionID: session.id) { $0.cursor >= 7 }
        #expect(afterLateCompletion.activeTurnID == "new-turn")
    }

    @Test func shutdownRejectsNewWork() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = BrokerFixture()
        let broker = try ConversationBroker(directory: root, adapters: [fixture.adapter])
        await broker.shutdown()
        await #expect(throws: (any Error).self) { _ = try await broker.createSession(createRequest()) }
    }

    private func createRequest() -> ConversationCreateRequest {
        ConversationCreateRequest(provider: .codex, workspaceID: "workspace", directory: "/tmp", launchTarget: .local(directory: "/tmp"), title: "Test")
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-conversation-broker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForSnapshot(_ broker: ConversationBroker, sessionID: ConversationID, predicate: (ConversationSnapshot) -> Bool) async throws -> ConversationSnapshot {
        // Register before taking the first snapshot so a provider event that
        // lands during the snapshot cannot be missed by a fixed yield-count
        // poll.  The broker's journal-backed stream is the causal wake-up.
        let events = await broker.events(sessionID: sessionID, after: 0)
        var snapshot = try await broker.snapshot(sessionID: sessionID)
        if predicate(snapshot) { return snapshot }
        for try await _ in events {
            snapshot = try await broker.snapshot(sessionID: sessionID)
            if predicate(snapshot) { return snapshot }
        }
        return snapshot
    }
}

private struct BrokerFixture: Sendable {
    let connection: BrokerFixtureConnection
    let adapter: BrokerFixtureAdapter

    init() {
        let connection = BrokerFixtureConnection()
        self.connection = connection
        self.adapter = BrokerFixtureAdapter(connection: connection)
    }
}

private struct BrokerFixtureAdapter: ConversationProviderAdapter, Sendable {
    let connection: BrokerFixtureConnection
    let provider: ConversationProvider = .codex
    let capabilities = ConversationCapabilities(protocolVersion: "fixture", features: ["turn/start", "turn/steer", "turn/interrupt"], supportsResume: true)
    func open(session: ConversationSession, target: ConversationLaunchTarget) async throws -> any ConversationProviderConnection { connection }
}

private actor BrokerFixtureConnection: ConversationProviderConnection {
    nonisolated let events: AsyncThrowingStream<ConversationProviderEvent, any Error>
    private let continuation: AsyncThrowingStream<ConversationProviderEvent, any Error>.Continuation
    private var sent: [ConversationCommand] = []
    private var closed = false

    init() {
        let pair = AsyncThrowingStream<ConversationProviderEvent, any Error>.makeStream()
        events = pair.stream
        continuation = pair.continuation
    }

    func providerSessionID() async -> String? { "fixture-native" }
    func capabilities() async -> ConversationCapabilities? { ConversationCapabilities(protocolVersion: "fixture", features: ["turn/start", "turn/steer", "turn/interrupt"], supportsResume: true) }
    func send(_ command: ConversationCommand) async throws {
        guard !closed else { throw ConversationProviderError.unavailable("fixture closed") }
        sent.append(command)
    }
    func sendCount(for command: ConversationCommand) -> Int { sent.filter { $0 == command }.count }
    func emit(_ event: ConversationProviderEvent) { continuation.yield(event) }
    func close() async { closed = true; continuation.finish() }
}
