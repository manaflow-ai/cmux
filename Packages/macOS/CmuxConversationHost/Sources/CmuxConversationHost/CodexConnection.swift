import Foundation
import CmuxConversation

/// One app-server thread. Native thread, turn and request IDs never come from the mobile client.
actor CodexConnection: ConversationProviderConnection {
    nonisolated let events: AsyncThrowingStream<ConversationProviderEvent, any Error>
    private let continuation: AsyncThrowingStream<ConversationProviderEvent, any Error>.Continuation
    private let transport: any ConversationNativeTransport
    private let session: ConversationSession
    private var threadID = ""
    private var turnID: String?
    private var sendingTurn = false
    private var closed = false
    private var reader: Task<Void, Never>?
    private var models: [String: [String: ConversationJSONValue]] = [:]
    private var selectedModel: String?
    private var selectedEffort: String?
    private var selectedSpeed: String?
    private var requests: [ConversationRequestID: PendingRequest] = [:]
    private var questionAnswers: [ConversationJSONValue: [String: ConversationJSONValue]] = [:]
    private var projection = CodexEventProjection()

    private struct PendingRequest: Sendable {
        let nativeID: ConversationJSONValue
        let method: String
        let params: [String: ConversationJSONValue]
        let request: ConversationRequest
        let questionID: String?
        let questionCount: Int
    }

    private init(transport: any ConversationNativeTransport, session: ConversationSession) {
        self.transport = transport; self.session = session
        let pair = AsyncThrowingStream<ConversationProviderEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1_024))
        events = pair.stream; continuation = pair.continuation
    }

    static func open(transport: any ConversationNativeTransport, session: ConversationSession) async throws -> CodexConnection {
        let connection = CodexConnection(transport: transport, session: session)
        do { try await connection.bootstrap(); return connection }
        catch { await connection.close(); throw error }
    }

    private func bootstrap() async throws {
        _ = try await call("initialize", ["clientInfo": .object(["name": .string("cmux"), "version": .string("1")]), "capabilities": .object(["experimentalApi": .bool(true)])])
        _ = try await transport.send(.object(["jsonrpc": .string("2.0"), "method": .string("initialized")]))
        var arguments: [String: ConversationJSONValue] = ["cwd": .string(session.directory)]
        let method: String
        if let existingID = session.providerSessionID { method = "thread/resume"; arguments["threadId"] = .string(existingID) }
        else { method = "thread/start" }
        let response = try await call(method, arguments)
        guard let thread = response.objectValue?["thread"]?.objectValue, let id = thread["id"]?.stringValue, !id.isEmpty else {
            throw ConversationProviderError.malformed("Codex did not return a native thread identifier")
        }
        threadID = id
        selectedModel = session.model ?? response.objectValue?["model"]?.stringValue
        selectedEffort = session.effort ?? response.objectValue?["reasoningEffort"]?.stringValue
        selectedSpeed = session.speed
        // Catalog failure does not prevent a provider-default conversation. It disables settings choices.
        var cursor: String?
        for _ in 0..<4 {
            var query: [String: ConversationJSONValue] = ["limit": .number("100")]
            if let cursor { query["cursor"] = .string(cursor) }
            guard let response = try? await call("model/list", query), let value = response.objectValue else { break }
            for model in value["data"]?.arrayValue ?? [] {
                if let object = model.objectValue, let name = object["model"]?.stringValue, object["hidden"]?.boolValue != true { models[name] = object }
            }
            cursor = value["nextCursor"]?.stringValue
            if cursor == nil { break }
        }
        // On resume the existing journal owns history. The stream only supplies new updates.
        if let active = (thread["turns"]?.arrayValue ?? []).compactMap(\.objectValue).last(where: { $0["status"]?.stringValue == "inProgress" }) {
            turnID = active["id"]?.stringValue
            try emit(.init(kind: .turn, turnID: turnID.map(ConversationTurnID.init(rawValue:)), state: "running"))
        }
        reader = Task { [weak self, transport] in
            do {
                for try await payload in transport.messages {
                    guard !Task.isCancelled else { return }
                    try await self?.receive(payload)
                }
                await self?.ended(ConversationProviderError.unavailable("Codex connection ended"))
            } catch { await self?.ended(error) }
        }
    }

    func providerSessionID() async -> String? { threadID.isEmpty ? nil : threadID }

    func capabilities() async -> ConversationCapabilities? {
        let efforts = Set(models.values.flatMap { ($0["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap { $0.objectValue?["reasoningEffort"]?.stringValue } })
        let speeds = Set(models.values.flatMap { ($0["serviceTiers"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue } })
        return ConversationCapabilities(protocolVersion: "codex-app-server/v2", features: ["turn/start", "turn/steer", "turn/interrupt", "approval", "question", "diff", "artifact", "configure"], models: models.keys.sorted(), efforts: efforts.sorted(), speeds: speeds.sorted(), supportsResume: true)
    }

    func send(_ command: ConversationCommand) async throws {
        guard !closed else { throw ConversationProviderError.unavailable("Codex connection is closed") }
        switch command {
        case .startTurn(let text, let model, let effort):
            guard turnID == nil, !sendingTurn else { throw ConversationProviderError.rejected("A turn is already active; queue or steer the message") }
            try validate(model: model ?? selectedModel, effort: effort ?? selectedEffort, speed: selectedSpeed)
            sendingTurn = true
            defer { sendingTurn = false }
            var params = input(text)
            if let model = model ?? selectedModel { params["model"] = .string(model) }
            if let effort = effort ?? selectedEffort { params["effort"] = .string(effort) }
            if let selectedSpeed { params["serviceTier"] = .string(selectedSpeed) }
            let response = try await call("turn/start", params)
            guard let turn = response.objectValue?["turn"]?.objectValue, let id = turn["id"]?.stringValue else { throw ConversationProviderError.malformed("Codex did not return a turn identifier") }
            // A fast completion notification may arrive before the request waiter resumes.
            if !projection.completedTurns.contains(id) {
                turnID = id
                try emit(.init(kind: .turn, turnID: .init(rawValue: id), state: "running", rawPayload: response))
            }
        case .steer(let text):
            guard let turnID else { throw ConversationProviderError.rejected("No active turn to steer") }
            var params = input(text); params["expectedTurnId"] = .string(turnID)
            _ = try await call("turn/steer", params)
        case .interrupt:
            guard let turnID else { throw ConversationProviderError.rejected("No active turn to stop") }
            _ = try await call("turn/interrupt", ["threadId": .string(threadID), "turnId": .string(turnID)])
        case .resolveApproval(let id, let decision): try await resolve(id, decision: decision)
        case .answerQuestion(let id, let answers): try await answer(id, answers: answers)
        case .configure(let model, let effort, let speed):
            try validate(model: model, effort: effort, speed: speed)
            selectedModel = model; selectedEffort = effort; selectedSpeed = speed
        case .queue, .editQueued, .cancelQueued, .rename, .setPinned, .setArchived:
            throw ConversationProviderError.rejected("This command is handled by the task journal")
        }
    }

    private func validate(model: String?, effort: String?, speed: String?) throws {
        let choice = model ?? selectedModel
        if let model, model != selectedModel, models[model] == nil { throw ConversationProviderError.rejected("The selected model is not available") }
        if let effort {
            let available = (choice.flatMap { models[$0] }?["supportedReasoningEfforts"]?.arrayValue ?? []).compactMap { $0.objectValue?["reasoningEffort"]?.stringValue }
            guard available.contains(effort) || (effort == selectedEffort && models.isEmpty) else { throw ConversationProviderError.rejected("This model does not offer the selected effort") }
        }
        if let speed {
            let available = (choice.flatMap { models[$0] }?["serviceTiers"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue }
            guard available.contains(speed) else { throw ConversationProviderError.rejected("This model does not offer the selected speed") }
        }
    }

    private func input(_ text: String) -> [String: ConversationJSONValue] {
        ["threadId": .string(threadID), "input": .array([.object(["type": .string("text"), "text": .string(text)])])]
    }

    private func call(_ method: String, _ params: [String: ConversationJSONValue]) async throws -> ConversationJSONValue {
        guard let result = try await transport.send(.object(["jsonrpc": .string("2.0"), "id": .string(UUID().uuidString), "method": .string(method), "params": .object(params)])) else {
            throw ConversationProviderError.malformed("Codex returned no request acknowledgment")
        }
        return result
    }

    private func receive(_ raw: ConversationJSONValue) throws {
        guard !closed, let object = raw.objectValue, let method = object["method"]?.stringValue else { return }
        let params = object["params"]?.objectValue ?? [:]
        if let source = params["threadId"]?.stringValue, source != threadID { return }
        if let nativeID = object["id"] { try request(method, nativeID: nativeID, params: params, raw: raw); return }
        if method == "serverRequest/resolved", let nativeID = params["requestId"] {
            for (id, pending) in requests where pending.nativeID == nativeID {
                try requestState(pending, state: .cancelled); requests.removeValue(forKey: id)
            }
            questionAnswers.removeValue(forKey: nativeID)
            return
        }
        let mapped = projection.events(method: method, params: params, raw: raw)
        for event in mapped {
            if event.kind == .turn {
                if event.state == "running" { turnID = event.turnID?.rawValue }
                else if event.turnID?.rawValue == turnID { turnID = nil }
            }
            try emit(event)
        }
    }

    private func request(_ method: String, nativeID: ConversationJSONValue, params: [String: ConversationJSONValue], raw: ConversationJSONValue) throws {
        let key = try JSONEncoder().encode(nativeID).base64EncodedString()
        let turn = params["turnId"]?.stringValue.map(ConversationTurnID.init(rawValue:))
        if method == "item/tool/requestUserInput" {
            let questions = params["questions"]?.arrayValue ?? []
            let identities = questions.compactMap { $0.objectValue?["id"]?.stringValue }
            guard !questions.isEmpty, identities.count == questions.count,
                  identities.allSatisfy({ !$0.isEmpty }), Set(identities).count == identities.count,
                  questions.allSatisfy({ $0.objectValue?["question"]?.stringValue?.isEmpty == false }) else {
                throw ConversationProviderError.malformed("Codex questions have incomplete or duplicate identities")
            }
            for (index, value) in questions.enumerated() {
                guard let question = value.objectValue, let questionID = question["id"]?.stringValue, let prompt = question["question"]?.stringValue else { throw ConversationProviderError.malformed("Codex question is incomplete") }
                let options = (question["options"]?.arrayValue ?? []).compactMap { option -> ConversationQuestionOption? in
                    guard let object = option.objectValue, let label = object["label"]?.stringValue else { return nil }
                    return .init(id: label, label: label, detail: object["description"]?.stringValue)
                }
                let request = ConversationRequest(id: .init(rawValue: "codex:\(key):\(index)"), turnID: turn, generation: session.generation, kind: params["isBlocking"]?.boolValue == false ? "question_async" : "question", question: .init(category: question["header"]?.stringValue, prompt: prompt, options: options, allowsCustomAnswer: options.isEmpty || question["isOther"]?.boolValue == true, isSecret: question["isSecret"]?.boolValue, index: index, total: questions.count), rawPayload: raw)
                requests[request.id] = PendingRequest(nativeID: nativeID, method: method, params: params, request: request, questionID: questionID, questionCount: questions.count)
                try emit(.init(kind: .request, turnID: turn, request: request, rawPayload: raw))
            }
        } else if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" || method == "item/permissions/requestApproval" {
            let request = ConversationRequest(id: .init(rawValue: "codex:\(key)"), turnID: turn, generation: session.generation, kind: "approval", approval: .init(summary: params["reason"]?.stringValue ?? (method.contains("fileChange") ? "Review file changes" : "Review command execution"), command: params["command"]?.stringValue ?? permissionDescription(params["permissions"]), supportsAlwaysAllow: params["proposedExecpolicyAmendment"]?.arrayValue?.isEmpty == false), rawPayload: raw)
            requests[request.id] = PendingRequest(nativeID: nativeID, method: method, params: params, request: request, questionID: nil, questionCount: 0)
            try emit(.init(kind: .request, turnID: turn, request: request, rawPayload: raw))
        } else {
            // Preserve new protocol requests for inspection; never invent an approval on their behalf.
            try emit(.init(kind: .unknown(method), itemKind: .unknown(method), state: "unsupported-request", rawPayload: raw))
        }
    }

    private func resolve(_ id: ConversationRequestID, decision: ConversationApprovalDecision) async throws {
        guard let pending = requests[id], pending.request.approval != nil else { throw ConversationProviderError.rejected("This approval is no longer pending") }
        if pending.method == "item/permissions/requestApproval" {
            guard decision != .alwaysApprove else { throw ConversationProviderError.rejected("This request grants permissions for one turn only") }
            guard let permissions = pending.params["permissions"], permissions.objectValue != nil else { throw ConversationProviderError.malformed("Permission request has no permissions") }
            _ = try await transport.send(.object(["jsonrpc": .string("2.0"), "id": pending.nativeID, "result": .object(["permissions": decision == .deny ? .object([:]) : permissions, "scope": .string("turn")])]))
            try requestState(pending, state: decision == .deny ? .denied : .approved)
            requests.removeValue(forKey: id)
            return
        }
        let nativeDecision: ConversationJSONValue
        switch decision {
        case .approve: nativeDecision = .string("accept")
        case .deny: nativeDecision = .string("decline")
        case .alwaysApprove:
            guard pending.request.approval?.supportsAlwaysAllow == true, let amendment = pending.params["proposedExecpolicyAmendment"] else { throw ConversationProviderError.rejected("This request does not offer a persistent rule") }
            nativeDecision = .object(["acceptWithExecpolicyAmendment": .object(["execpolicy_amendment": amendment])])
        }
        _ = try await transport.send(.object(["jsonrpc": .string("2.0"), "id": pending.nativeID, "result": .object(["decision": nativeDecision])]))
        try requestState(pending, state: decision == .deny ? .denied : .approved)
        requests.removeValue(forKey: id)
    }

    private func answer(_ id: ConversationRequestID, answers: [ConversationQuestionAnswer]) async throws {
        guard let pending = requests[id], let questionID = pending.questionID, let answer = answers.first(where: { $0.index == pending.request.question?.index }) ?? (answers.count == 1 ? answers.first : nil) else { throw ConversationProviderError.rejected("This question is no longer pending") }
        let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text?.isEmpty != false || pending.request.question?.allowsCustomAnswer == true else {
            throw ConversationProviderError.rejected("This question requires an offered answer")
        }
        guard let value = (text?.isEmpty == false ? text : answer.optionID), !value.isEmpty else { throw ConversationProviderError.rejected("An answer is required") }
        if text?.isEmpty != false, let optionID = answer.optionID, pending.request.question?.options.contains(where: { $0.id == optionID }) != true { throw ConversationProviderError.rejected("The selected answer is not offered") }
        questionAnswers[pending.nativeID, default: [:]][questionID] = .object(["answers": .array([.string(value)])])
        if questionAnswers[pending.nativeID]?.count == pending.questionCount {
            _ = try await transport.send(.object(["jsonrpc": .string("2.0"), "id": pending.nativeID, "result": .object(["answers": .object(questionAnswers[pending.nativeID] ?? [:])])]))
            questionAnswers.removeValue(forKey: pending.nativeID)
        }
        try requestState(pending, state: .answered)
        requests.removeValue(forKey: id)
    }

    private func permissionDescription(_ value: ConversationJSONValue?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func requestState(_ pending: PendingRequest, state: ConversationRequestState) throws {
        var request = pending.request; request.state = state
        try emit(.init(kind: .request, turnID: request.turnID, request: request))
    }

    private func emit(_ event: ConversationProviderEvent) throws {
        if case .dropped = continuation.yield(event) { throw ConversationProviderError.unavailable("Codex event buffer overflow; reconnect to restore journal state") }
    }

    private func ended(_ error: any Error) async {
        guard !closed else { return }
        closed = true
        continuation.finish(throwing: error)
        await transport.close()
    }

    func close() async {
        guard !closed else { return }
        closed = true; reader?.cancel(); reader = nil
        continuation.finish()
        await transport.close()
    }
}

extension ConversationJSONValue {
    var arrayValue: [ConversationJSONValue]? { if case .array(let value) = self { value } else { nil } }
}
