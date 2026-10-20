import Foundation
import Testing
import CmuxConversation
@testable import CmuxConversationHost

@Suite struct OpenCodeConnectionTests {
    @Test func nativeSessionIsCreatedAndPromptCarriesItsID() async throws {
        let transport = OpenCodeFixtureTransport()
        let connection = try await OpenCodeConnection.open(transport: transport, session: metadata())
        try await connection.send(.startTurn(text: "Test", model: "provider/model", effort: "high"))
        let request = await transport.sent.last?.objectValue
        #expect(request?["method"] == .string("session.prompt"))
        #expect(request?["params"]?.objectValue?["sessionID"] == .string("ses_native"))
        #expect(request?["params"]?.objectValue?["body"]?.objectValue?["model"] == .object(["providerID": .string("provider"), "modelID": .string("model")]))
        #expect(await connection.providerSessionID() == "ses_native")
        await connection.close()
    }

    @Test func resumeReadsExistingSessionAndNeverCreatesReplacement() async throws {
        let transport = OpenCodeFixtureTransport()
        let connection = try await OpenCodeConnection.open(transport: transport, session: metadata(nativeID: "ses_previous"))
        #expect(await transport.sent.first?.objectValue?["method"] == .string("session.get"))
        #expect(await transport.sent.first?.objectValue?["params"]?.objectValue?["sessionID"] == .string("ses_previous"))
        #expect(await transport.sent.contains { $0.objectValue?["method"] == .string("session.create") } == false)
        await connection.close()
    }

    @Test func foreignEventsCannotCreateApprovalInThisConversation() async throws {
        let transport = OpenCodeFixtureTransport()
        let connection = try await OpenCodeConnection.open(transport: transport, session: metadata())
        var iterator = connection.events.makeAsyncIterator()
        await transport.emit(permission(session: "ses_foreign", id: "per_foreign"))
        await transport.emit(permission(session: "ses_native", id: "per_native"))
        let event = try #require(try await iterator.next())
        #expect(event.request?.id == .init(rawValue: "per_native"))
        try await connection.send(.resolveApproval(requestID: .init(rawValue: "per_native"), decision: .deny))
        #expect(await transport.sent.last?.objectValue?["params"]?.objectValue?["body"] == .object(["reply": .string("reject")]))
        await connection.close()
    }

    @Test func unsupportedSteerAndSpeedAreNeverSimulatedAsSuccess() async throws {
        let transport = OpenCodeFixtureTransport()
        let connection = try await OpenCodeConnection.open(transport: transport, session: metadata())
        let count = await transport.sent.count
        await #expect(throws: (any Error).self) { try await connection.send(.steer(text: "later")) }
        await #expect(throws: (any Error).self) { try await connection.send(.configure(model: nil, effort: nil, speed: "fast")) }
        #expect(await transport.sent.count == count)
        #expect(await connection.capabilities()?.features.contains("turn/steer") == false)
        await connection.close()
    }

    @Test(arguments: [("APIError", "failed"), ("MessageAbortedError", "stopped")])
    func idlePreservesTheNativeFailureOutcome(error: String, expectedState: String) async throws {
        let transport = OpenCodeFixtureTransport()
        let connection = try await OpenCodeConnection.open(transport: transport, session: metadata())
        var iterator = connection.events.makeAsyncIterator()
        try await connection.send(.startTurn(text: "Test", model: nil, effort: nil))
        let started = try #require(try await iterator.next())
        #expect(started.state == "running")
        await transport.emit(.object(["type": .string("session.error"), "properties": .object(["sessionID": .string("ses_native"), "error": .object(["name": .string(error)])])]))
        await transport.emit(.object(["type": .string("session.status"), "properties": .object(["sessionID": .string("ses_native"), "status": .object(["type": .string("idle")])])]))
        let failure = try #require(try await iterator.next())
        #expect(failure.itemKind == .error)
        let finished = try #require(try await iterator.next())
        #expect(finished.state == expectedState)
        #expect(finished.turnID == started.turnID)
        try await connection.send(.startTurn(text: "Next", model: nil, effort: nil))
        let next = try #require(try await iterator.next())
        #expect(next.state == "running")
        #expect(next.turnID != started.turnID)
        await transport.emit(.object(["type": .string("session.idle"), "properties": .object(["sessionID": .string("ses_native")])]))
        await transport.emit(permission(session: "ses_native", id: "per_next"))
        let request = try #require(try await iterator.next())
        #expect(request.kind == .request)
        #expect(request.turnID == next.turnID)
        await connection.close()
    }

    @Test func eventFramingHandlesCRLFMultilineAndUTF8() throws {
        var decoder = OpenCodeSSEDecoder()
        let wire = ": heartbeat\r\nevent: update\r\ndata: {\"type\":\"message\",\r\ndata: \"text\":\"مرحبا\"}\r\n\r\n"
        var values: [ConversationJSONValue] = []
        for byte in wire.utf8 { if let value = try decoder.append(byte) { values.append(value) } }
        #expect(values == [.object(["type": .string("message"), "text": .string("مرحبا")])])
    }

    @Test func oversizedEventFailsBeforeAnyPayloadIsEmitted() throws {
        var decoder = OpenCodeSSEDecoder(maximumBytes: 16)
        #expect(throws: (any Error).self) {
            for byte in "data: {\"text\":\"too much content\"}\n\n".utf8 { _ = try decoder.append(byte) }
        }
    }

    private func metadata(nativeID: String? = nil) -> ConversationSession {
        .init(id: "cmux-session", provider: .openCode, title: "Task", workspaceID: "workspace", directory: "/tmp", providerSessionID: nativeID)
    }
    private func permission(session: String, id: String) -> ConversationJSONValue {
        .object(["type": .string("permission.asked"), "properties": .object(["sessionID": .string(session), "id": .string(id), "permission": .string("shell"), "patterns": .array([.string("git status")]), "always": .array([])])])
    }
}

private actor OpenCodeFixtureTransport: ConversationNativeTransport {
    nonisolated let messages: AsyncThrowingStream<ConversationJSONValue, any Error>
    private let continuation: AsyncThrowingStream<ConversationJSONValue, any Error>.Continuation
    private(set) var sent: [ConversationJSONValue] = []
    init() {
        let pair = AsyncThrowingStream<ConversationJSONValue, any Error>.makeStream()
        messages = pair.stream; continuation = pair.continuation
    }
    func send(_ payload: ConversationJSONValue) async throws -> ConversationJSONValue? {
        sent.append(payload)
        switch payload.objectValue?["method"]?.stringValue {
        case "session.create", "session.get": return .object(["id": .string("ses_native")])
        case "provider.list": return .object(["connected": .array([.string("provider")]), "all": .array([.object(["id": .string("provider"), "models": .object(["model": .object(["variants": .object(["high": .object([:])])])])])])])
        case "permission.reply", "question.reply", "session.abort": return .bool(true)
        default: return .null
        }
    }
    func emit(_ value: ConversationJSONValue) { continuation.yield(value) }
    func close() async { continuation.finish() }
}
