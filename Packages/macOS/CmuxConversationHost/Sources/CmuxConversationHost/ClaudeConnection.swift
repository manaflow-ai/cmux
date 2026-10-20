import Foundation
import CmuxConversation

/// One Claude stream-json session, correlated by native session and echoed user UUIDs.
actor ClaudeConnection: ConversationProviderConnection {
    nonisolated let events: AsyncThrowingStream<ConversationProviderEvent, any Error>
    private let continuation: AsyncThrowingStream<ConversationProviderEvent, any Error>.Continuation
    private let transport: any ConversationNativeTransport
    private let session: ConversationSession
    private let nativeSessionID: String
    private let acknowledgmentTimeout: Duration
    private var activeTurnID: ConversationTurnID?
    private var reader: Task<Void, Never>?
    private var closed = false
    private var modelNames: [String] = []
    private var selectedModel: String?
    private var requests: [ConversationRequestID: PendingRequest] = [:]
    private var answers: [String: [String: String]] = [:]
    private var pendingSends: [String: CheckedContinuation<ConversationJSONValue, any Error>] = [:]
    private var sendDeadlines: [String: Task<Void, Never>] = [:]
    private var projection = ClaudeEventProjection()

    private struct PendingRequest: Sendable {
        let nativeID: String
        let request: ConversationRequest
        let input: [String: ConversationJSONValue]
        let questionCount: Int
    }

    private init(transport: any ConversationNativeTransport, session: ConversationSession, acknowledgmentTimeout: Duration) {
        self.transport = transport; self.session = session
        // The process factory passes this UUID through Claude's documented --session-id option.
        nativeSessionID = session.providerSessionID ?? session.id.rawValue
        selectedModel = session.model
        self.acknowledgmentTimeout = acknowledgmentTimeout
        let pair = AsyncThrowingStream<ConversationProviderEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1_024))
        events = pair.stream; continuation = pair.continuation
    }

    static func open(transport: any ConversationNativeTransport, session: ConversationSession, acknowledgmentTimeout: Duration = .seconds(45)) async throws -> ClaudeConnection {
        let connection = ClaudeConnection(transport: transport, session: session, acknowledgmentTimeout: acknowledgmentTimeout)
        do { try await connection.bootstrap(); return connection }
        catch { await connection.close(); throw error }
    }

    private func bootstrap() async throws {
        let response = try await controlCall(subtype: "initialize", payload: [:])
        modelNames = (response["models"]?.arrayValue ?? []).compactMap { $0.objectValue?["value"]?.stringValue }
        if let selectedModel { _ = try await controlCall(subtype: "set_model", payload: ["model": .string(selectedModel)]) }
        reader = Task { [weak self, transport] in
            do {
                for try await payload in transport.messages {
                    try Task.checkCancellation(); try await self?.receive(payload)
                }
                await self?.end(ConversationProviderError.unavailable("Claude Code connection ended"))
            } catch { await self?.end(error) }
        }
    }

    func providerSessionID() async -> String? { nativeSessionID }
    func capabilities() async -> ConversationCapabilities? {
        .init(protocolVersion: "claude-stream-json/v1", features: ["turn/start", "turn/interrupt", "approval", "question", "child", "configure"], models: modelNames, supportsResume: true)
    }

    func send(_ command: ConversationCommand) async throws {
        guard !closed else { throw ConversationProviderError.unavailable("Claude Code connection is closed") }
        switch command {
        case .startTurn(let text, let model, let effort):
            guard activeTurnID == nil else { throw ConversationProviderError.rejected("A turn is active; queue the message") }
            guard effort == nil else { throw ConversationProviderError.unsupported("This Claude connection does not advertise effort controls") }
            if let model, model != selectedModel { try await configure(model: model, effort: nil, speed: nil) }
            try await sendUser(text: text)
        case .steer:
            // A second stream-json user message is queued/folded by Claude; that is not an acknowledged same-turn steer.
            throw ConversationProviderError.unsupported("This Claude connection does not expose same-turn steering")
        case .interrupt:
            guard activeTurnID != nil else { throw ConversationProviderError.rejected("No active turn to stop") }
            _ = try await controlCall(subtype: "interrupt", payload: [:])
        case .configure(let model, let effort, let speed): try await configure(model: model, effort: effort, speed: speed)
        case .resolveApproval(let id, let decision): try await resolve(id, decision: decision)
        case .answerQuestion(let id, let values): try await answer(id, values: values)
        case .queue, .editQueued, .cancelQueued, .rename, .setPinned, .setArchived:
            throw ConversationProviderError.rejected("This command is handled by the task journal")
        }
    }

    private func configure(model: String?, effort: String?, speed: String?) async throws {
        guard effort == nil, speed == nil else { throw ConversationProviderError.unsupported("This Claude connection does not advertise effort or speed controls") }
        if let model, !modelNames.contains(model) { throw ConversationProviderError.rejected("The selected Claude model is not available") }
        _ = try await controlCall(subtype: "set_model", payload: ["model": model.map(ConversationJSONValue.string) ?? .null])
        selectedModel = model
    }

    private func sendUser(text: String) async throws {
        let uuid = UUID().uuidString
        let turn = ConversationTurnID(rawValue: uuid)
        activeTurnID = turn
        let payload: ConversationJSONValue = .object([
            "type": .string("user"), "uuid": .string(uuid), "session_id": .string(nativeSessionID),
            "parent_tool_use_id": .null,
            "message": .object(["role": .string("user"), "content": .string(text)]),
        ])
        let acknowledgment = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                pendingSends[uuid] = waiter
                sendDeadlines[uuid] = Task { [weak self, acknowledgmentTimeout] in
                    do { try await Task.sleep(for: acknowledgmentTimeout) } catch { return }
                    await self?.end(ConversationProviderError.unavailable("Claude did not acknowledge the message; delivery is uncertain"))
                }
                Task { [weak self, transport] in
                    do { _ = try await transport.send(payload) }
                    catch { await self?.end(error) }
                }
            }
        } onCancel: { Task { await self.end(CancellationError()) } }
        try emit(.init(kind: .item, itemID: .init(rawValue: "user:" + uuid), turnID: turn, itemKind: .message, role: "user", text: text, rawPayload: acknowledgment))
    }

    private func controlCall(subtype: String, payload: [String: ConversationJSONValue]) async throws -> [String: ConversationJSONValue] {
        let requestID = UUID().uuidString
        var request = payload; request["subtype"] = .string(subtype)
        let result = try await transport.send(.object(["type": .string("control_request"), "request_id": .string(requestID), "request": .object(request)]))
        // ProcessConversationTransport returns the matched control_response.response envelope.
        guard let response = result?.objectValue, response["request_id"]?.stringValue == requestID,
              response["subtype"]?.stringValue == "success" else { throw ConversationProviderError.malformed("Claude returned an invalid control acknowledgment") }
        return response["response"]?.objectValue ?? [:]
    }

    private func receive(_ raw: ConversationJSONValue) throws {
        guard !closed, let value = raw.objectValue else { return }
        if let id = value["session_id"]?.stringValue, id != nativeSessionID { return }
        let type = value["type"]?.stringValue ?? "unknown"
        let isMainThread = value["parent_tool_use_id"]?.stringValue == nil
        if isMainThread {
            var echoes = (value["user_message_uuids"]?.arrayValue ?? []).compactMap(\.stringValue)
            if let id = value["user_message_uuid"]?.stringValue { echoes.append(id) }
            if type == "user", let id = value["uuid"]?.stringValue { echoes.append(id) }
            for id in echoes {
                if let waiter = pendingSends.removeValue(forKey: id) {
                    sendDeadlines.removeValue(forKey: id)?.cancel()
                    waiter.resume(returning: raw)
                    try emit(.init(kind: .turn, turnID: .init(rawValue: id), state: "running", rawPayload: raw))
                }
            }
        }
        if type == "control_request" { try receiveRequest(value, raw: raw); return }
        if type == "control_cancel_request", let id = value["request_id"]?.stringValue {
            for (key, request) in requests where request.nativeID == id { try settle(request, state: .cancelled); requests.removeValue(forKey: key) }
            answers.removeValue(forKey: id); return
        }
        let eventTurn = activeTurnID
        if type == "result", isMainThread {
            let turn = value["user_message_uuid"]?.stringValue.map(ConversationTurnID.init(rawValue:)) ?? activeTurnID
            try emit(.init(kind: .turn, turnID: turn, state: value["is_error"]?.boolValue == true ? "failed" : "completed", rawPayload: raw))
            if turn == activeTurnID { activeTurnID = nil }
        }
        for event in try projection.events(raw, turnID: eventTurn) { try emit(event) }
    }

    private func receiveRequest(_ value: [String: ConversationJSONValue], raw: ConversationJSONValue) throws {
        guard let nativeID = value["request_id"]?.stringValue, let body = value["request"]?.objectValue else { throw ConversationProviderError.malformed("Claude request has no identity") }
        let subtype = body["subtype"]?.stringValue ?? "unknown"
        guard subtype == "can_use_tool" else { try emit(.init(kind: .unknown("control_request." + subtype), rawPayload: raw)); return }
        let input = body["input"]?.objectValue ?? [:]
        if body["tool_name"]?.stringValue == "AskUserQuestion" {
            let questions = input["questions"]?.arrayValue ?? []
            guard !questions.isEmpty else { throw ConversationProviderError.malformed("Claude question has no questions") }
            let prompts = questions.compactMap { $0.objectValue?["question"]?.stringValue }
            // Claude keys the final answer map by prompt. Ambiguous prompts
            // cannot be answered without silently dropping one answer.
            guard prompts.count == questions.count, Set(prompts).count == prompts.count,
                  prompts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw ConversationProviderError.malformed("Claude questions do not have distinct prompts")
            }
            for (index, value) in questions.enumerated() {
                guard let question = value.objectValue, let prompt = question["question"]?.stringValue else { throw ConversationProviderError.malformed("Claude question is incomplete") }
                let options = (question["options"]?.arrayValue ?? []).compactMap { option -> ConversationQuestionOption? in
                    guard let value = option.objectValue, let label = value["label"]?.stringValue else { return nil }
                    return .init(id: label, label: label, detail: value["description"]?.stringValue)
                }
                let request = ConversationRequest(id: .init(rawValue: "claude:\(nativeID):\(index)"), turnID: activeTurnID, generation: session.generation, kind: "question", question: .init(category: question["header"]?.stringValue, prompt: prompt, options: options, allowsCustomAnswer: true, index: index, total: questions.count), rawPayload: raw)
                requests[request.id] = .init(nativeID: nativeID, request: request, input: input, questionCount: questions.count)
                try emit(.init(kind: .request, turnID: activeTurnID, request: request, rawPayload: raw))
            }
        } else {
            let summary = [body["tool_name"]?.stringValue, body["decision_reason"]?.stringValue].compactMap { $0 }.joined(separator: " — ")
            let command = input["command"]?.stringValue ?? pretty(.object(input))
            let request = ConversationRequest(id: .init(rawValue: "claude:" + nativeID), turnID: activeTurnID, generation: session.generation, kind: "approval", approval: .init(summary: summary, command: command, supportsAlwaysAllow: false), rawPayload: raw)
            requests[request.id] = .init(nativeID: nativeID, request: request, input: input, questionCount: 0)
            try emit(.init(kind: .request, turnID: activeTurnID, request: request, rawPayload: raw))
        }
    }

    private func resolve(_ id: ConversationRequestID, decision: ConversationApprovalDecision) async throws {
        guard let pending = requests[id], pending.request.approval != nil else { throw ConversationProviderError.rejected("This approval is no longer pending") }
        guard decision != .alwaysApprove else { throw ConversationProviderError.unsupported("This request offers approval for one tool call") }
        let response: ConversationJSONValue = decision == .approve
            ? .object(["behavior": .string("allow"), "updatedInput": .object(pending.input)])
            : .object(["behavior": .string("deny"), "message": .string("Denied by user")])
        try await reply(pending.nativeID, response: response)
        try settle(pending, state: decision == .approve ? .approved : .denied); requests.removeValue(forKey: id)
    }

    private func answer(_ id: ConversationRequestID, values: [ConversationQuestionAnswer]) async throws {
        guard let pending = requests[id], let question = pending.request.question,
              let answer = values.first(where: { $0.index == question.index }) ?? (values.count == 1 ? values.first : nil) else { throw ConversationProviderError.rejected("This question is no longer pending") }
        let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = text?.isEmpty == false ? text : answer.optionID, !value.isEmpty else { throw ConversationProviderError.rejected("An answer is required") }
        if text?.isEmpty != false, !question.options.contains(where: { $0.id == value }) { throw ConversationProviderError.rejected("The selected answer is not offered") }
        answers[pending.nativeID, default: [:]][question.prompt] = value
        if answers[pending.nativeID]?.count == pending.questionCount {
            var input = pending.input
            input["answers"] = .object((answers[pending.nativeID] ?? [:]).mapValues(ConversationJSONValue.string))
            try await reply(pending.nativeID, response: .object(["behavior": .string("allow"), "updatedInput": .object(input)]))
            answers.removeValue(forKey: pending.nativeID)
        }
        try settle(pending, state: .answered); requests.removeValue(forKey: id)
    }

    private func reply(_ id: String, response: ConversationJSONValue) async throws {
        _ = try await transport.send(.object(["type": .string("control_response"), "response": .object(["subtype": .string("success"), "request_id": .string(id), "response": response])]))
    }
    private func settle(_ pending: PendingRequest, state: ConversationRequestState) throws {
        var request = pending.request; request.state = state
        try emit(.init(kind: .request, turnID: request.turnID, request: request))
    }
    private func pretty(_ value: ConversationJSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    private func emit(_ event: ConversationProviderEvent) throws {
        if case .dropped = continuation.yield(event) { throw ConversationProviderError.unavailable("Claude event buffer overflow") }
    }
    private func end(_ error: any Error) async {
        guard !closed else { return }; closed = true
        reader?.cancel(); reader = nil; continuation.finish(throwing: error)
        for deadline in sendDeadlines.values { deadline.cancel() }; sendDeadlines.removeAll()
        for waiter in pendingSends.values { waiter.resume(throwing: error) }; pendingSends.removeAll()
        await transport.close()
    }
    func close() async { await end(ConversationProviderError.unavailable("Claude connection closed")) }
}
