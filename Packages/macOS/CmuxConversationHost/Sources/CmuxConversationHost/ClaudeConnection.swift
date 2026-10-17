public import Foundation
public import CmuxConversation

/// A Claude Code bidirectional streaming-json connection.
actor ClaudeConnection: ConversationProviderConnection {
    nonisolated let events: AsyncThrowingStream<ConversationProviderEvent, any Error>
    private let continuation: AsyncThrowingStream<ConversationProviderEvent, any Error>.Continuation
    private let transport: any ConversationNativeTransport
    private let session: ConversationSession
    private var nativeSessionID: String?
    private var activeTurnID: ConversationTurnID?
    private var requests: [ConversationRequestID: PendingRequest] = [:]
    private var reader: Task<Void, Never>?
    private var closed = false
    private var modelNames: [String] = []

    private struct PendingRequest: Sendable {
        let nativeID: String
        let request: ConversationRequest
        let subtype: String
    }

    private init(transport: any ConversationNativeTransport, session: ConversationSession) {
        self.transport = transport
        self.session = session
        let pair = AsyncThrowingStream<ConversationProviderEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1_024))
        events = pair.stream
        continuation = pair.continuation
    }

    static func open(transport: any ConversationNativeTransport, session: ConversationSession) async throws -> ClaudeConnection {
        let connection = ClaudeConnection(transport: transport, session: session)
        do { try await connection.bootstrap(); return connection }
        catch { await connection.close(); throw error }
    }

    private func bootstrap() async throws {
        let response = try await controlCall(subtype: "initialize", payload: [:])
        if let sessionID = response["session_id"]?.stringValue { nativeSessionID = sessionID }
        if let models = response["models"]?.arrayValue { modelNames = models.compactMap(\.stringValue) }
        reader = Task { [weak self, transport] in
            do {
                for try await payload in transport.messages {
                    guard !Task.isCancelled else { return }
                    try await self?.receive(payload)
                }
                await self?.end(ConversationProviderError.unavailable("Claude Code connection ended"))
            } catch { await self?.end(error) }
        }
    }

    func providerSessionID() async -> String? { nativeSessionID }

    func capabilities() async -> ConversationCapabilities? {
        ConversationCapabilities(protocolVersion: "claude-streaming-json/v1", features: ["streaming", "interrupt", "approval", "question", "child"], models: modelNames, supportsResume: nativeSessionID != nil)
    }

    func send(_ command: ConversationCommand) async throws {
        guard !closed else { throw ConversationProviderError.unavailable("Claude Code connection is closed") }
        switch command {
        case .startTurn(let text, let model, let effort):
            guard activeTurnID == nil else { throw ConversationProviderError.rejected("A turn is active; queue or steer the message") }
            guard model == nil || modelNames.isEmpty || modelNames.contains(model!) else { throw ConversationProviderError.rejected("The selected Claude model is not available") }
            guard effort == nil else { throw ConversationProviderError.unsupported("Claude effort settings are provider-version dependent") }
            let id = ConversationItemID(rawValue: "user:" + UUID().uuidString)
            try await sendUser(text: text)
            try emit(.init(kind: .item, itemID: id, itemKind: .message, role: "user", text: text))
        case .steer(let text):
            guard activeTurnID != nil else { throw ConversationProviderError.rejected("No active turn to steer") }
            try await sendUser(text: text)
            try emit(.init(kind: .item, itemID: .init(rawValue: "user:" + UUID().uuidString), turnID: activeTurnID, itemKind: .message, role: "user", text: text))
        case .interrupt:
            guard activeTurnID != nil else { throw ConversationProviderError.rejected("No active turn to stop") }
            _ = try await controlCall(subtype: "interrupt", payload: [:])
        case .answerQuestion(let requestID, let answers): try await answer(requestID, answers: answers)
        case .resolveApproval(let requestID, let decision): try await resolve(requestID, decision: decision)
        case .configure: throw ConversationProviderError.unsupported("Claude model settings are provider-version dependent")
        case .queue, .editQueued, .cancelQueued, .rename, .setPinned, .setArchived:
            throw ConversationProviderError.rejected("This command is handled by the task journal")
        }
    }

    private func sendUser(text: String) async throws {
        let payload: ConversationJSONValue = .object([
            "type": .string("user"),
            "message": .object(["role": .string("user"), "content": .string(text)]),
            "session_id": nativeSessionID.map(ConversationJSONValue.string) ?? .null,
        ])
        _ = try await transport.send(payload)
    }

    private func controlCall(subtype: String, payload: [String: ConversationJSONValue]) async throws -> [String: ConversationJSONValue] {
        let requestID = UUID().uuidString
        var request = payload
        request["subtype"] = .string(subtype)
        let result = try await transport.send(.object(["type": .string("control_request"), "request_id": .string(requestID), "request": .object(request)]))
        guard let response = result?.objectValue?["response"]?.objectValue ?? result?.objectValue,
              response["request_id"]?.stringValue == requestID || response["subtype"]?.stringValue == "success" else {
            throw ConversationProviderError.malformed("Claude control response did not match request")
        }
        if response["subtype"]?.stringValue == "error" { throw ConversationProviderError.rejected("Claude Code rejected the control request") }
        return response["response"]?.objectValue ?? [:]
    }

    private func receive(_ payload: ConversationJSONValue) throws {
        guard !closed, let object = payload.objectValue else { return }
        let type = object["type"]?.stringValue ?? "unknown"
        if type == "control_request" { try receiveRequest(object, raw: payload); return }
        if type == "system" {
            if let id = object["session_id"]?.stringValue { nativeSessionID = id }
            try emit(.init(kind: .run, state: object["subtype"]?.stringValue, rawPayload: payload)); return
        }
        if type == "result" {
            let failed = object["is_error"]?.boolValue == true
            try emit(.init(kind: .turn, turnID: activeTurnID, state: failed ? "failed" : "completed", rawPayload: payload))
            activeTurnID = nil
            return
        }
        if type == "assistant" || type == "message_start" || type == "message_delta" || type == "content_block_delta" {
            let message = object["message"]?.objectValue ?? object
            let delta = object["delta"]?.objectValue?["text"]?.stringValue ?? object["delta"]?.stringValue ?? object["text"]?.stringValue ?? message["content"]?.stringValue
            let itemID = object["uuid"]?.stringValue ?? object["id"]?.stringValue ?? UUID().uuidString
            if activeTurnID == nil { activeTurnID = .init(rawValue: object["turn_id"]?.stringValue ?? object["session_id"]?.stringValue ?? UUID().uuidString) }
            try emit(.init(kind: .item, itemID: .init(rawValue: itemID), turnID: activeTurnID, itemKind: .message, role: "assistant", text: delta, rawPayload: payload)); return
        }
        if type == "user" {
            let message = object["message"]?.objectValue ?? object
            let text = message["content"]?.stringValue ?? object["text"]?.stringValue
            try emit(.init(kind: .item, itemID: .init(rawValue: object["uuid"]?.stringValue ?? UUID().uuidString), turnID: activeTurnID, itemKind: .message, role: "user", text: text, rawPayload: payload)); return
        }
        if type == "tool_use" || type == "tool_result" {
            let toolID = object["id"]?.stringValue ?? UUID().uuidString
            let status: ConversationToolStatus = type == "tool_result" ? .success : .running
            let tool = ConversationTool(toolID: toolID, name: object["name"]?.stringValue ?? "Tool", input: object["input"], output: object["content"], status: status)
            try emit(.init(kind: .item, itemID: .init(rawValue: toolID), turnID: activeTurnID, itemKind: .tool, tool: tool, rawPayload: payload)); return
        }
        try emit(.init(kind: .unknown(type), rawPayload: payload))
    }

    private func receiveRequest(_ object: [String: ConversationJSONValue], raw: ConversationJSONValue) throws {
        guard let nativeID = object["request_id"]?.stringValue else { throw ConversationProviderError.malformed("Claude control request has no request_id") }
        let requestBody = object["request"]?.objectValue ?? [:]
        let subtype = requestBody["subtype"]?.stringValue ?? "unknown"
        let requestID = ConversationRequestID(rawValue: "claude:" + nativeID)
        if subtype == "can_use_tool" || requestBody["tool_name"] != nil {
            let input = requestBody["input"]?.objectValue ?? [:]
            let toolName = requestBody["tool_name"]?.stringValue ?? "Tool permission"
            let request = ConversationRequest(id: requestID, turnID: activeTurnID, generation: session.generation, kind: "approval", approval: .init(summary: toolName, command: input["command"]?.stringValue, supportsAlwaysAllow: false), rawPayload: raw)
            requests[requestID] = PendingRequest(nativeID: nativeID, request: request, subtype: subtype)
            try emit(.init(kind: .request, turnID: activeTurnID, request: request, rawPayload: raw)); return
        }
        if subtype == "ask_user_question" || requestBody["questions"] != nil {
            let questions = requestBody["questions"]?.arrayValue ?? []
            for (index, value) in questions.enumerated() {
                let question = value.objectValue ?? [:]
                let options = (question["options"]?.arrayValue ?? []).compactMap { option -> ConversationQuestionOption? in guard let object = option.objectValue, let label = object["label"]?.stringValue else { return nil }; return .init(id: label, label: label, detail: object["description"]?.stringValue) }
                let req = ConversationRequest(id: .init(rawValue: "\(requestID.rawValue):\(index)"), turnID: activeTurnID, generation: session.generation, kind: "question", question: .init(category: question["header"]?.stringValue, prompt: question["question"]?.stringValue ?? "Input required", options: options, allowsCustomAnswer: true, index: index, total: questions.count), rawPayload: raw)
                requests[req.id] = PendingRequest(nativeID: nativeID, request: req, subtype: subtype)
                try emit(.init(kind: .request, turnID: activeTurnID, request: req, rawPayload: raw))
            }
            return
        }
        try emit(.init(kind: .unknown("control_request.\(subtype)"), rawPayload: raw))
    }

    private func resolve(_ id: ConversationRequestID, decision: ConversationApprovalDecision) async throws {
        guard let pending = requests[id] else { throw ConversationProviderError.rejected("This approval is no longer pending") }
        guard decision != .alwaysApprove else { throw ConversationProviderError.unsupported("Claude does not expose persistent approval rules in this protocol") }
        let response: ConversationJSONValue = decision == .approve ? .object(["behavior": .string("allow")]) : .object(["behavior": .string("deny"), "message": .string("Denied by user")])
        _ = try await transport.send(.object(["type": .string("control_response"), "response": .object(["subtype": .string("success"), "request_id": .string(pending.nativeID), "response": response])]))
        var request = pending.request; request.state = decision == .approve ? .approved : .denied
        try emit(.init(kind: .request, turnID: request.turnID, request: request)); requests.removeValue(forKey: id)
    }

    private func answer(_ id: ConversationRequestID, answers: [ConversationQuestionAnswer]) async throws {
        guard let pending = requests[id], let question = pending.request.question, let answer = answers.first(where: { $0.index == question.index }) ?? answers.first else { throw ConversationProviderError.rejected("This question is no longer pending") }
        let value = answer.text?.isEmpty == false ? answer.text! : (answer.optionID ?? "")
        guard !value.isEmpty else { throw ConversationProviderError.rejected("An answer is required") }
        let response: ConversationJSONValue = .object(["answers": .array([.string(value)])])
        _ = try await transport.send(.object(["type": .string("control_response"), "response": .object(["subtype": .string("success"), "request_id": .string(pending.nativeID), "response": response])]))
        var request = pending.request; request.state = .answered
        try emit(.init(kind: .request, turnID: request.turnID, request: request)); requests.removeValue(forKey: id)
    }

    private func emit(_ event: ConversationProviderEvent) throws {
        if case .dropped = continuation.yield(event) { throw ConversationProviderError.unavailable("Claude event buffer overflow; replay required") }
    }

    private func end(_ error: any Error) async {
        guard !closed else { return }; closed = true; continuation.finish(throwing: error); await transport.close()
    }

    func close() async { guard !closed else { return }; closed = true; reader?.cancel(); reader = nil; continuation.finish(); await transport.close() }
}
