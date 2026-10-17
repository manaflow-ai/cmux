import Foundation
import Testing
import CmuxConversation
@testable import CmuxConversationHost

@Suite struct CodexConnectionTests {
    @Test func handshakeWaitsForAcknowledgmentAndUsesNativeThreadIdentity() async throws {
        let transport = CodexFixtureTransport()
        let connection = try await CodexConnection.open(transport: transport, session: session())
        try await connection.send(.startTurn(text: "Hello", model: nil, effort: nil))
        let sent = await transport.sent
        #expect(sent.prefix(4).compactMap { $0.objectValue?["method"]?.stringValue } == ["initialize", "initialized", "thread/start", "model/list"])
        #expect(sent.last?.objectValue?["params"]?.objectValue?["threadId"] == .string("native-thread"))
        #expect(await connection.providerSessionID() == "native-thread")
        await connection.close()
    }

    @Test func resumeUsesPersistedProviderIDAndRetainsProviderPermissionDefaults() async throws {
        let transport = CodexFixtureTransport()
        let connection = try await CodexConnection.open(transport: transport, session: session(nativeID: "previous-thread"))
        let request = await transport.sent.first { $0.objectValue?["method"] == .string("thread/resume") }
        #expect(request?.objectValue?["params"]?.objectValue?["threadId"] == .string("previous-thread"))
        #expect(request?.objectValue?["params"]?.objectValue?["approvalPolicy"] == nil)
        #expect(request?.objectValue?["params"]?.objectValue?["sandbox"] == nil)
        await connection.close()
    }

    @Test func approvalResponseUsesOriginalNumericRequestID() async throws {
        let transport = CodexFixtureTransport()
        let connection = try await CodexConnection.open(transport: transport, session: session())
        var iterator = connection.events.makeAsyncIterator()
        await transport.emit(.object(["id": .number("41"), "method": .string("item/commandExecution/requestApproval"), "params": .object(["threadId": .string("native-thread"), "turnId": .string("turn"), "itemId": .string("command"), "command": .string("git status")])]))
        let event = try #require(try await iterator.next())
        let request = try #require(event.request)
        #expect(request.approval?.command == "git status")
        try await connection.send(.resolveApproval(requestID: request.id, decision: .deny))
        let response = await transport.sent.last
        #expect(response?.objectValue?["id"] == .number("41"))
        #expect(response?.objectValue?["result"]?.objectValue?["decision"] == .string("decline"))
        await #expect(throws: (any Error).self) { try await connection.send(.resolveApproval(requestID: request.id, decision: .approve)) }
        await connection.close()
    }

    @Test func multipleQuestionsProduceOneNativeResponseAfterEveryAnswer() async throws {
        let transport = CodexFixtureTransport()
        let connection = try await CodexConnection.open(transport: transport, session: session())
        var iterator = connection.events.makeAsyncIterator()
        let questions: [ConversationJSONValue] = ["first", "second"].map { .object(["id": .string($0), "question": .string($0), "header": .string("Choice")]) }
        await transport.emit(.object(["id": .string("questions"), "method": .string("item/tool/requestUserInput"), "params": .object(["threadId": .string("native-thread"), "turnId": .string("turn"), "questions": .array(questions)])]))
        let first = try #require(try await iterator.next()?.request)
        let second = try #require(try await iterator.next()?.request)
        try await connection.send(.answerQuestion(requestID: first.id, answers: [.init(index: 0, text: "one")]))
        #expect(await transport.sent.filter { $0.objectValue?["result"] != nil }.isEmpty)
        try await connection.send(.answerQuestion(requestID: second.id, answers: [.init(index: 1, text: "two")]))
        let result = await transport.sent.last?.objectValue?["result"]?.objectValue?["answers"]?.objectValue
        #expect(result?["first"]?.objectValue?["answers"] == .array([.string("one")]))
        #expect(result?["second"]?.objectValue?["answers"] == .array([.string("two")]))
        await connection.close()
    }

    @Test func unsupportedSettingsFailWithoutSendingProviderWork() async throws {
        let transport = CodexFixtureTransport()
        let connection = try await CodexConnection.open(transport: transport, session: session())
        let count = await transport.sent.count
        await #expect(throws: (any Error).self) { try await connection.send(.configure(model: "invented", effort: nil, speed: nil)) }
        #expect(await transport.sent.count == count)
        await connection.close()
    }

    @Test func nativeQuestionInputConstraintsArePreserved() async throws {
        let transport = CodexFixtureTransport()
        let connection = try await CodexConnection.open(transport: transport, session: session())
        var iterator = connection.events.makeAsyncIterator()
        let question: ConversationJSONValue = .object(["id": .string("choice"), "question": .string("Choose"), "isOther": .bool(false), "isSecret": .bool(true), "options": .array([.object(["label": .string("Offered")])])])
        await transport.emit(.object(["id": .string("request"), "method": .string("item/tool/requestUserInput"), "params": .object(["threadId": .string("native-thread"), "questions": .array([question])])]))
        let request = try #require(try await iterator.next()?.request)
        #expect(request.question?.allowsCustomAnswer == false)
        #expect(request.question?.isSecret == true)
        await #expect(throws: (any Error).self) {
            try await connection.send(.answerQuestion(requestID: request.id, answers: [.init(index: 0, text: "Unlisted")]))
        }
        try await connection.send(.answerQuestion(requestID: request.id, answers: [.init(index: 0, optionID: "Offered")]))
        let result = await transport.sent.last?.objectValue?["result"]?.objectValue?["answers"]?.objectValue
        #expect(result?["choice"]?.objectValue?["answers"] == .array([.string("Offered")]))
        await connection.close()
    }

    @Test func deltasStayCompactAndCompletionRemainsAuthoritative() {
        var projection = CodexEventProjection()
        let params: [String: ConversationJSONValue] = ["threadId": .string("thread"), "turnId": .string("turn"), "itemId": .string("item"), "delta": .string("part")]
        #expect(projection.events(method: "item/agentMessage/delta", params: params, raw: .null).first?.text == "part")
        let second = projection.events(method: "item/agentMessage/delta", params: params, raw: .null).first
        #expect(second?.text == "part")
        #expect(second?.itemUpdate == .appendText)
        let completed: [String: ConversationJSONValue] = ["turnId": .string("turn"), "item": .object(["id": .string("item"), "type": .string("agentMessage"), "text": .string("final")])]
        #expect(projection.events(method: "item/completed", params: completed, raw: .null).first?.text == "final")
    }

    private func session(nativeID: String? = nil) -> ConversationSession {
        .init(id: .init(rawValue: "cmux-id"), provider: .codex, title: "Task", workspaceID: "workspace", directory: "/tmp", providerSessionID: nativeID, generation: "generation")
    }
}

private actor CodexFixtureTransport: ConversationNativeTransport {
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
        case "initialize": return .object([:])
        case "thread/start", "thread/resume": return .object(["thread": .object(["id": .string("native-thread"), "turns": .array([])])])
        case "model/list": return .object(["data": .array([])])
        case "turn/start": return .object(["turn": .object(["id": .string("native-turn"), "status": .string("inProgress")])])
        case "turn/steer", "turn/interrupt": return .object([:])
        default: return nil
        }
    }
    func emit(_ value: ConversationJSONValue) { continuation.yield(value) }
    func close() async { continuation.finish() }
}
