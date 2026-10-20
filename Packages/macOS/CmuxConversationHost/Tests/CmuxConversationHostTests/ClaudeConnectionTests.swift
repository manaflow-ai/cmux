import Foundation
import Testing
import CmuxConversation
@testable import CmuxConversationHost

@Suite struct ClaudeConnectionTests {
    private func session() -> ConversationSession {
        .init(id: .init(rawValue: "8BDDB32C-53F1-4B50-9594-567DA2156550"), provider: .claudeCode, title: "Task", workspaceID: "workspace", directory: "/tmp", generation: "generation")
    }

    @Test func initializesCatalogAndRequiresTheEchoedUserIdentity() async throws {
        let transport = ClaudeFixtureTransport()
        let connection = try await ClaudeConnection.open(transport: transport, session: session())
        #expect(await connection.providerSessionID() == session().id.rawValue)
        #expect(await connection.capabilities()?.models == ["sonnet"])
        #expect(await connection.capabilities()?.features.contains("turn/steer") == false)
        try await connection.send(.startTurn(text: "hello", model: nil, effort: nil))
        let user = try #require(await transport.sent.first { $0.objectValue?["type"] == .string("user") }?.objectValue)
        #expect(user["session_id"] == .string(session().id.rawValue))
        #expect(user["uuid"]?.stringValue != nil)
        await #expect(throws: (any Error).self) { try await connection.send(.startTurn(text: "again", model: nil, effort: nil)) }
        await connection.close()
    }

    @Test func successfulPipeWriteWithoutNativeEchoIsUncertain() async throws {
        let transport = ClaudeFixtureTransport(echoes: false)
        let connection = try await ClaudeConnection.open(transport: transport, session: session(), acknowledgmentTimeout: .milliseconds(30))
        do {
            try await connection.send(.startTurn(text: "hello", model: nil, effort: nil))
            Issue.record("Unacknowledged prompt must not become applied")
        } catch let error as ConversationProviderError { #expect(error.description.contains("uncertain")) }
        #expect(await transport.sent.filter { $0.objectValue?["type"] == .string("user") }.count == 1)
        await connection.close()
    }

    @Test func modelSelectionUsesAcknowledgedControlAndUnsupportedEffortFails() async throws {
        let transport = ClaudeFixtureTransport()
        let connection = try await ClaudeConnection.open(transport: transport, session: session())
        try await connection.send(.configure(model: "sonnet", effort: nil, speed: nil))
        #expect(await transport.sent.last?.objectValue?["request"]?.objectValue?["subtype"] == .string("set_model"))
        let count = await transport.sent.count
        await #expect(throws: (any Error).self) { try await connection.send(.configure(model: "sonnet", effort: "high", speed: nil)) }
        #expect(await transport.sent.count == count)
        await connection.close()
    }

    @Test func nativeAskUserQuestionAccumulatesAnswersIntoOnePermissionResponse() async throws {
        let transport = ClaudeFixtureTransport()
        let connection = try await ClaudeConnection.open(transport: transport, session: session())
        var iterator = connection.events.makeAsyncIterator()
        let questions: [ConversationJSONValue] = ["First?", "Second?"].map {
            .object(["question": .string($0), "header": .string("Choice"), "options": .array([.object(["label": .string("Yes"), "description": .string("Proceed")])])])
        }
        await transport.emit(.object(["type": .string("control_request"), "request_id": .string("native-question"), "request": .object(["subtype": .string("can_use_tool"), "tool_name": .string("AskUserQuestion"), "input": .object(["questions": .array(questions)])])]))
        let first = try #require(try await iterator.next()?.request)
        let second = try #require(try await iterator.next()?.request)
        #expect(first.kind == "question")
        try await connection.send(.answerQuestion(requestID: first.id, answers: [.init(index: 0, optionID: "Yes")]))
        #expect(await transport.sent.filter { $0.objectValue?["type"] == .string("control_response") }.isEmpty)
        try await connection.send(.answerQuestion(requestID: second.id, answers: [.init(index: 1, text: "Custom")]))
        let response = try #require(await transport.sent.last?.objectValue?["response"]?.objectValue)
        #expect(response["request_id"] == .string("native-question"))
        let permission = try #require(response["response"]?.objectValue)
        #expect(permission["behavior"] == .string("allow"))
        #expect(permission["updatedInput"]?.objectValue?["answers"] == .object(["First?": .string("Yes"), "Second?": .string("Custom")]))
        await connection.close()
    }

    @Test func nestedStreamDeltasAndCompleteBlockShareOneItemIdentity() throws {
        var projection = ClaudeEventProjection()
        let turn = ConversationTurnID(rawValue: "turn")
        func stream(_ event: [String: ConversationJSONValue]) -> ConversationJSONValue { .object(["type": .string("stream_event"), "event": .object(event)]) }
        _ = try projection.events(stream(["type": .string("message_start"), "message": .object(["id": .string("message")])]), turnID: turn)
        _ = try projection.events(stream(["type": .string("content_block_start"), "index": .number("0"), "content_block": .object(["type": .string("text"), "text": .string("")])]), turnID: turn)
        let delta = try projection.events(stream(["type": .string("content_block_delta"), "index": .number("0"), "delta": .object(["type": .string("text_delta"), "text": .string("Partial")])]), turnID: turn)
        let completed = try projection.events(.object(["type": .string("assistant"), "uuid": .string("complete"), "message": .object(["id": .string("message"), "content": .array([.object(["type": .string("text"), "text": .string("Final")])])])]), turnID: turn)
        #expect(delta.first?.text == "Partial")
        #expect(completed.first?.text == "Final")
        #expect(delta.first?.itemID == completed.first?.itemID)
    }

    @Test func ambiguousQuestionPromptsFailBeforePublishingPartialRequests() async throws {
        let transport = ClaudeFixtureTransport()
        let connection = try await ClaudeConnection.open(transport: transport, session: session())
        var iterator = connection.events.makeAsyncIterator()
        let question: ConversationJSONValue = .object(["question": .string("Repeated?"), "options": .array([])])
        await transport.emit(.object(["type": .string("control_request"), "request_id": .string("ambiguous"), "request": .object(["subtype": .string("can_use_tool"), "tool_name": .string("AskUserQuestion"), "input": .object(["questions": .array([question, question])])])]))
        do {
            _ = try await iterator.next()
            Issue.record("Ambiguous native question keys must fail before publishing requests")
        } catch let error as ConversationProviderError {
            #expect(error.description.contains("distinct prompts"))
        }
        await connection.close()
    }

    @Test func toolCompletionRequiresItsNativeResult() throws {
        var projection = ClaudeEventProjection()
        let tool = try projection.events(.object(["type": .string("assistant"), "message": .object(["id": .string("message"), "content": .array([.object(["type": .string("tool_use"), "id": .string("tool"), "name": .string("Bash"), "input": .object(["command": .string("pwd")])])])])]), turnID: .init(rawValue: "turn"))
        #expect(tool.first?.tool?.status == .running)
        let stopped = try projection.events(.object(["type": .string("result"), "uuid": .string("stopped")]), turnID: .init(rawValue: "turn"))
        #expect(stopped.allSatisfy { $0.tool == nil })
        let result = try projection.events(.object(["type": .string("user"), "message": .object(["content": .array([.object(["type": .string("tool_result"), "tool_use_id": .string("tool"), "content": .string("/tmp")])])])]), turnID: nil)
        #expect(result.first?.itemID == tool.first?.itemID)
        #expect(result.first?.tool?.status == .success)
    }
}

private actor ClaudeFixtureTransport: ConversationNativeTransport {
    nonisolated let messages: AsyncThrowingStream<ConversationJSONValue, any Error>
    private let continuation: AsyncThrowingStream<ConversationJSONValue, any Error>.Continuation
    private let echoes: Bool
    private(set) var sent: [ConversationJSONValue] = []
    init(echoes: Bool = true) {
        self.echoes = echoes
        let pair = AsyncThrowingStream<ConversationJSONValue, any Error>.makeStream()
        messages = pair.stream; continuation = pair.continuation
    }
    func send(_ payload: ConversationJSONValue) async throws -> ConversationJSONValue? {
        sent.append(payload)
        let value = payload.objectValue ?? [:]
        if value["type"] == .string("control_request") {
            let response: ConversationJSONValue = value["request"]?.objectValue?["subtype"] == .string("initialize")
                ? .object(["models": .array([.object(["value": .string("sonnet")])])]) : .object([:])
            return .object(["subtype": .string("success"), "request_id": value["request_id"]!, "response": response])
        }
        if value["type"] == .string("user"), echoes { continuation.yield(payload) }
        return nil
    }
    func emit(_ payload: ConversationJSONValue) { continuation.yield(payload) }
    func close() async { continuation.finish() }
}
