import CmuxConversation
import Foundation
import Testing
@testable import CmuxMobileRPC

@Suite struct MobileConversationClientTests {
    @Test func lostCommandReplyIsReconciledWithoutRedispatchAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = ConversationConnectionProbe()
        let client = try MobileConversationClient(
            connection: connection, workspaceIDs: ["workspace"],
            outboxURL: directory.appendingPathComponent("outbox.json")
        )
        let command = ConversationCommandEnvelope(
            commandID: "command", sessionID: "session", expectedGeneration: "generation",
            command: .startTurn(text: "Run this once", model: nil, effort: nil)
        )
        #expect(try await client.execute(command).state == .uncertain)
        let reconnected = try MobileConversationClient(
            connection: connection, workspaceIDs: ["workspace"],
            outboxURL: directory.appendingPathComponent("outbox.json")
        )
        let snapshot = try await reconnected.snapshot(sessionID: "session")
        #expect(snapshot.receipts.first?.state == .applied)
        #expect(await connection.commandCount == 1)
        #expect(await connection.receiptCount == 1)
    }

    @Test func unconfirmedCommandSurvivesAsUncertainInsteadOfResending() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = ConversationConnectionProbe()
        await connection.setHasReceipt(false)
        let client = try MobileConversationClient(
            connection: connection, workspaceIDs: ["workspace"],
            outboxURL: directory.appendingPathComponent("outbox.json")
        )
        _ = try await client.execute(.init(
            commandID: "command", sessionID: "session", expectedGeneration: "generation", command: .interrupt
        ))
        let snapshot = try await client.snapshot(sessionID: "session")
        #expect(snapshot.receipts.first?.state == .uncertain)
        #expect(await connection.commandCount == 1)
    }

    @Test func foreignSessionCannotBeDispatchedThroughAnAuthorizedWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = ConversationConnectionProbe()
        let client = try MobileConversationClient(
            connection: connection, workspaceIDs: ["workspace"],
            outboxURL: directory.appendingPathComponent("outbox.json")
        )
        await #expect(throws: (any Error).self) {
            _ = try await client.execute(.init(commandID: "command", sessionID: "foreign", command: .interrupt))
        }
        #expect(await connection.commandCount == 0)
    }

    @Test func streamRegistersBeforeReplayAndRejectsACursorGap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let connection = ConversationConnectionProbe()
        let client = try MobileConversationClient(
            connection: connection, workspaceIDs: ["workspace"],
            outboxURL: directory.appendingPathComponent("outbox.json")
        )
        let stream = await client.events(sessionID: "session")
        await #expect(throws: (any Error).self) {
            for try await _ in stream { Issue.record("A gapped event must not reach the projection") }
        }
        #expect(await connection.subscriptionInstalledBeforeACK)
    }
}

private actor ConversationConnectionProbe: MobileSyncing {
    private var listener: AsyncStream<MobileEventEnvelope>.Continuation?
    private var hasReceipt = true
    private(set) var commandCount = 0
    private(set) var receiptCount = 0
    private(set) var subscriptionInstalledBeforeACK = false

    func setHasReceipt(_ value: Bool) { hasReceipt = value }
    func disconnect() { listener?.finish() }
    func subscribe(to topics: Set<String>) -> AsyncStream<MobileEventEnvelope> {
        let pair = AsyncStream<MobileEventEnvelope>.makeStream()
        listener = pair.continuation
        return pair.stream
    }

    func sendRequest(_ requestData: Data, timeoutNanoseconds: UInt64?) throws -> Data {
        let request = try #require(JSONSerialization.jsonObject(with: requestData) as? [String: Any])
        let method = try #require(request["method"] as? String)
        let session = ConversationSession(
            id: "session", provider: .codex, title: "Task", workspaceID: "workspace", directory: "/tmp",
            generation: "generation", state: .ready
        )
        switch method {
        case "mobile.events.subscribe":
            subscriptionInstalledBeforeACK = listener != nil
            return Data(#"{"stream_id":"mobile-conversation-v1"}"#.utf8)
        case "mobile.conversation.list": return try response([session])
        case "mobile.conversation.snapshot":
            return try response(ConversationSnapshot(
                session: session, cursor: 0, generation: session.generation,
                capabilities: .init(protocolVersion: "test/1", supportsResume: true)
            ))
        case "mobile.conversation.command":
            commandCount += 1
            throw MobileConversationTransportError.disconnected
        case "mobile.conversation.receipt":
            receiptCount += 1
            let receipt: ConversationReceipt? = hasReceipt ? .init(
                id: "command", sessionID: "session", state: .applied, generation: "generation"
            ) : nil
            return try response(receipt)
        case "mobile.conversation.replay":
            return try response([ConversationEvent(sessionID: "session", sequence: 2, generation: "generation", kind: .turn)])
        default: throw MobileConversationTransportError.invalidResponse
        }
    }

    private func response<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(ProbeResponse(value: value))
    }

    private struct ProbeResponse<Value: Encodable>: Encodable { let value: Value }
}
