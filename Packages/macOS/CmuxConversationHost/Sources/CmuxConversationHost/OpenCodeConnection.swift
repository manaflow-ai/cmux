import Foundation
import CmuxConversation

/// A native OpenCode session, with events scoped to the server-assigned ID.
actor OpenCodeConnection: ConversationProviderConnection {
    nonisolated let events: AsyncThrowingStream<ConversationProviderEvent, any Error>
    private let continuation: AsyncThrowingStream<ConversationProviderEvent, any Error>.Continuation
    private let transport: any ConversationNativeTransport
    private let session: ConversationSession
    private var nativeID = ""
    private var activeMessageID: String?
    private var terminalState: String?
    private var reader: Task<Void, Never>?
    private var closed = false
    private var models: [String: [String: ConversationJSONValue]] = [:]
    private var selectedModel: String?
    private var selectedEffort: String?
    private var messageRoles: [String: String] = [:]
    private var parts: [String: [String: ConversationJSONValue]] = [:]
    private var pending: [ConversationRequestID: NativeRequest] = [:]
    private var answers: [String: [Int: String]] = [:]

    private struct NativeRequest: Sendable {
        let id: String
        let request: ConversationRequest
        let questionIndex: Int?
        let questionCount: Int
    }

    private init(transport: any ConversationNativeTransport, session: ConversationSession) {
        self.transport = transport; self.session = session
        selectedModel = session.model; selectedEffort = session.effort
        let pair = AsyncThrowingStream<ConversationProviderEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(1_024))
        events = pair.stream; continuation = pair.continuation
    }

    static func open(transport: any ConversationNativeTransport, session: ConversationSession) async throws -> OpenCodeConnection {
        let connection = OpenCodeConnection(transport: transport, session: session)
        do { try await connection.bootstrap(); return connection } catch { await connection.close(); throw error }
    }

    private func bootstrap() async throws {
        let result: ConversationJSONValue
        if let id = session.providerSessionID { result = try await call("session.get", ["sessionID": .string(id)]) }
        else { result = try await call("session.create", ["title": .string(session.title)]) }
        guard let id = result.objectValue?["id"]?.stringValue, !id.isEmpty else { throw ConversationProviderError.malformed("OpenCode returned no native session identifier") }
        nativeID = id
        if let catalog = try? await call("provider.list", [:]), let object = catalog.objectValue {
            let connected = Set((object["connected"]?.arrayValue ?? []).compactMap(\.stringValue))
            for provider in object["all"]?.arrayValue ?? [] {
                guard let value = provider.objectValue, let providerID = value["id"]?.stringValue, connected.contains(providerID) else { continue }
                for (modelID, model) in value["models"]?.objectValue ?? [:] {
                    if let model = model.objectValue { models[providerID + "/" + modelID] = model }
                }
            }
        }
        reader = Task { [weak self, transport] in
            do {
                for try await value in transport.messages {
                    try Task.checkCancellation(); try await self?.receive(value)
                }
                await self?.ended(ConversationProviderError.unavailable("OpenCode connection ended"))
            } catch { await self?.ended(error) }
        }
    }

    func providerSessionID() async -> String? { nativeID.isEmpty ? nil : nativeID }
    func capabilities() async -> ConversationCapabilities? {
        .init(protocolVersion: "opencode-http/v1", features: ["turn/start", "turn/interrupt", "approval", "question", "diff", "artifact", "configure"], models: models.keys.sorted(), efforts: Set(models.values.flatMap { Array(($0["variants"]?.objectValue ?? [:]).keys) }).sorted(), supportsResume: true)
    }

    func send(_ command: ConversationCommand) async throws {
        guard !closed else { throw ConversationProviderError.unavailable("OpenCode connection is closed") }
        switch command {
        case .startTurn(let text, let model, let effort):
            guard activeMessageID == nil else { throw ConversationProviderError.rejected("A turn is active; queue this message") }
            let model = model ?? selectedModel; let effort = effort ?? selectedEffort
            try validate(model: model, effort: effort)
            // OpenCode accepts a client-generated native message ID, which becomes
            // the turn precondition used for this run. It is never a session ID.
            let messageID = "msg" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            var body: [String: ConversationJSONValue] = ["messageID": .string(messageID), "parts": .array([.object(["type": .string("text"), "text": .string(text)])])]
            if let model { body["model"] = try nativeModel(model) }
            if let effort { body["variant"] = .string(effort) }
            activeMessageID = messageID
            terminalState = nil
            try emit(.init(kind: .turn, turnID: .init(rawValue: messageID), state: "running"))
            do { _ = try await call("session.prompt", ["sessionID": .string(nativeID), "body": .object(body)]) }
            catch let error as ConversationProviderError {
                if case .rejected = error {
                    activeMessageID = nil
                    try emit(.init(kind: .turn, turnID: .init(rawValue: messageID), state: "failed"))
                }
                throw error
            }
        case .interrupt:
            guard activeMessageID != nil else { throw ConversationProviderError.rejected("No active turn to stop") }
            let accepted = try await call("session.abort", ["sessionID": .string(nativeID)])
            guard accepted == .bool(true) else { throw ConversationProviderError.rejected("OpenCode did not accept the stop request") }
            // Tool states only change when their native part events arrive.
        case .steer: throw ConversationProviderError.unsupported("This OpenCode protocol does not expose same-turn steering")
        case .configure(let model, let effort, let speed):
            guard speed == nil else { throw ConversationProviderError.unsupported("OpenCode does not advertise response speed settings") }
            try validate(model: model, effort: effort); selectedModel = model; selectedEffort = effort
        case .resolveApproval(let id, let decision):
            guard let request = pending[id], request.request.approval != nil else { throw ConversationProviderError.rejected("This permission request is no longer pending") }
            if decision == .alwaysApprove, request.request.approval?.supportsAlwaysAllow != true { throw ConversationProviderError.rejected("This permission does not offer a persistent rule") }
            let reply = decision == .approve ? "once" : (decision == .alwaysApprove ? "always" : "reject")
            let accepted = try await call("permission.reply", ["requestID": .string(request.id), "body": .object(["reply": .string(reply)])])
            guard accepted == .bool(true) else { throw ConversationProviderError.rejected("OpenCode did not accept the permission response") }
            try resolve(request, state: decision == .deny ? .denied : .approved); pending.removeValue(forKey: id)
        case .answerQuestion(let id, let values): try await answer(id, values)
        case .queue, .editQueued, .cancelQueued, .rename, .setPinned, .setArchived:
            throw ConversationProviderError.rejected("This command is handled by the task journal")
        }
    }

    private func validate(model: String?, effort: String?) throws {
        if let model, models[model] == nil { throw ConversationProviderError.rejected("The selected OpenCode model is not connected") }
        if let effort {
            guard let model, models[model]?["variants"]?.objectValue?[effort] != nil else { throw ConversationProviderError.rejected("This model does not offer the selected effort") }
        }
    }
    private func nativeModel(_ value: String) throws -> ConversationJSONValue {
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw ConversationProviderError.rejected("Invalid model identifier") }
        return .object(["providerID": .string(parts[0]), "modelID": .string(parts[1])])
    }
    private func call(_ method: String, _ params: [String: ConversationJSONValue]) async throws -> ConversationJSONValue {
        guard let result = try await transport.send(.object(["method": .string(method), "params": .object(params)])) else { throw ConversationProviderError.malformed("OpenCode returned no acknowledgment") }
        return result
    }

    private func receive(_ raw: ConversationJSONValue) throws {
        guard !closed, let object = raw.objectValue, let type = object["type"]?.stringValue else { return }
        let value = object["properties"]?.objectValue ?? [:]
        let source = value["sessionID"]?.stringValue ?? value["part"]?.objectValue?["sessionID"]?.stringValue ?? value["info"]?.objectValue?["sessionID"]?.stringValue ?? (type.hasPrefix("session.") ? value["info"]?.objectValue?["id"]?.stringValue : nil)
        guard source == nativeID else { return }
        let turn = activeMessageID.map(ConversationTurnID.init(rawValue:))
        switch type {
        case "session.idle":
            // The legacy idle notification follows session.status(idle). Only
            // the status transition finishes the turn, so this cannot finish
            // a queued turn started between those two notifications.
            break
        case "session.status":
            let status = value["status"]?.objectValue?["type"]?.stringValue
            if status == "idle" {
                try finishTurn(raw: raw)
            } else if status == "busy" || status == "retry" {
                try emit(.init(kind: .run, turnID: turn, state: "running", rawPayload: raw))
            }
        case "session.error":
            terminalState = failureState(value["error"])
            try emit(.init(kind: .item, turnID: turn, itemKind: .error, text: "OpenCode reported a provider error", rawPayload: raw))
        case "message.part.updated":
            if let part = value["part"]?.objectValue, let id = part["id"]?.stringValue { parts[id] = part; try emitPart(part, turn: turn, raw: raw) }
        case "message.part.delta":
            guard let id = value["partID"]?.stringValue, let delta = value["delta"]?.stringValue, let field = value["field"]?.stringValue, field == "text" else { try emit(.init(kind: .unknown(type), rawPayload: raw)); return }
            var part = parts[id] ?? ["id": .string(id), "type": .string("text"), "messageID": value["messageID"] ?? .null]
            let accumulated = (part["text"]?.stringValue ?? "") + delta
            guard accumulated.utf8.count <= 1_048_576 else { throw ConversationProviderError.malformed("OpenCode text exceeds the event limit") }
            part["text"] = .string(accumulated); parts[id] = part
            try emitPart(part, turn: turn, raw: raw, textDelta: delta)
        case "message.updated":
            if let info = value["info"]?.objectValue, let id = info["id"]?.stringValue, let role = info["role"]?.stringValue {
                messageRoles[id] = role
                // Some server versions deliver the part first. Repair its role when metadata arrives.
                for part in parts.values where part["messageID"]?.stringValue == id { try emitPart(part, turn: turn, raw: raw) }
            }
            if let info = value["info"]?.objectValue, info["role"]?.stringValue == "assistant", let id = info["id"]?.stringValue {
                if let error = info["error"], error != .null { terminalState = failureState(error) }
                let tokens = info["tokens"]?.objectValue ?? [:]
                try emit(.init(kind: .item, itemID: .init(rawValue: "usage:" + id), turnID: turn, itemKind: .usage, usage: .init(inputTokens: tokens["input"]?.numberValue.flatMap(Int64.init), outputTokens: tokens["output"]?.numberValue.flatMap(Int64.init), cachedTokens: tokens["cache"]?.objectValue?["read"]?.numberValue.flatMap(Int64.init), model: info["modelID"]?.stringValue), rawPayload: raw))
            }
        case "permission.asked": try permission(value, turn: turn, raw: raw)
        case "question.asked": try questions(value, turn: turn, raw: raw)
        case "permission.replied", "question.replied", "question.rejected":
            if let id = value["requestID"]?.stringValue {
                for (key, request) in pending where request.id == id { try resolve(request, state: type == "question.rejected" ? .skipped : .answered); pending.removeValue(forKey: key) }
                answers.removeValue(forKey: id)
            }
        case "session.diff":
            for (index, file) in (value["diff"]?.arrayValue ?? []).enumerated() {
                guard let file = file.objectValue, let path = file["file"]?.stringValue else { continue }
                let before = file["before"]?.stringValue ?? ""; let after = file["after"]?.stringValue ?? ""
                let removed = before.split(separator: "\n", omittingEmptySubsequences: false)
                let added = after.split(separator: "\n", omittingEmptySubsequences: false)
                let diff = "--- a/\(path)\n+++ b/\(path)\n@@ -1,\(removed.count) +1,\(added.count) @@\n" + removed.map { "-" + $0 }.joined(separator: "\n") + "\n" + added.map { "+" + $0 }.joined(separator: "\n")
                try emit(.init(kind: .item, itemID: .init(rawValue: "diff:\(turn?.rawValue ?? nativeID):\(index)"), turnID: turn, itemKind: .files, diff: .init(path: path, text: diff, comparison: "last-turn"), rawPayload: raw))
            }
        default: try emit(.init(kind: .unknown(type), rawPayload: raw))
        }
    }

    private func failureState(_ error: ConversationJSONValue?) -> String {
        error?.objectValue?["name"]?.stringValue == "MessageAbortedError" ? "stopped" : "failed"
    }

    private func finishTurn(raw: ConversationJSONValue) throws {
        // Initial idle status has no active turn and must not manufacture success.
        guard let id = activeMessageID else { return }
        try emit(.init(kind: .turn, turnID: .init(rawValue: id), state: terminalState ?? "completed", rawPayload: raw))
        activeMessageID = nil; terminalState = nil; parts.removeAll(); messageRoles.removeAll()
    }

    private func emitPart(_ part: [String: ConversationJSONValue], turn: ConversationTurnID?, raw: ConversationJSONValue, textDelta: String? = nil) throws {
        guard let rawID = part["id"]?.stringValue, let type = part["type"]?.stringValue else { return }
        let id = ConversationItemID(rawValue: rawID)
        switch type {
        case "text", "reasoning":
            try emit(.init(kind: .item, itemID: id, turnID: turn, itemKind: type == "text" ? .message : .reasoning, itemUpdate: textDelta == nil ? nil : .appendText, role: part["messageID"]?.stringValue.flatMap { messageRoles[$0] }, text: textDelta ?? part["text"]?.stringValue, rawPayload: raw))
        case "tool":
            let state = part["state"]?.objectValue ?? [:]
            let status: ConversationToolStatus
            switch state["status"]?.stringValue { case "pending": status = .queued; case "running": status = .running; case "completed": status = .success; case "error": status = .failed; default: status = .unknown }
            try emit(.init(kind: .item, itemID: id, turnID: turn, itemKind: .tool, tool: .init(toolID: part["callID"]?.stringValue ?? rawID, name: part["tool"]?.stringValue ?? "Tool", input: state["input"], output: state["output"] ?? state["error"], status: status), rawPayload: raw))
        case "file":
            guard let url = part["url"]?.stringValue, let file = URL(string: url), file.isFileURL else { try emit(.init(kind: .item, itemID: id, turnID: turn, itemKind: .unknown(type), rawPayload: raw)); return }
            try emit(.init(kind: .item, itemID: id, turnID: turn, itemKind: .artifact, artifact: .init(artifactID: rawID, fileName: part["filename"]?.stringValue ?? file.lastPathComponent, mediaType: part["mime"]?.stringValue ?? "application/octet-stream", remoteURL: url), rawPayload: raw))
        case "subtask", "agent": try emit(.init(kind: .item, itemID: id, turnID: turn, itemKind: .child, text: part["description"]?.stringValue ?? part["name"]?.stringValue ?? part["agent"]?.stringValue, rawPayload: raw))
        default: try emit(.init(kind: .item, itemID: id, turnID: turn, itemKind: .unknown(type), rawPayload: raw))
        }
    }

    private func permission(_ value: [String: ConversationJSONValue], turn: ConversationTurnID?, raw: ConversationJSONValue) throws {
        guard let id = value["id"]?.stringValue else { throw ConversationProviderError.malformed("OpenCode permission has no identifier") }
        let metadata = value["metadata"]?.objectValue ?? [:]
        let summary = value["permission"]?.stringValue ?? "Permission required"
        let command = metadata["command"]?.stringValue ?? (value["patterns"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "\n")
        let request = ConversationRequest(id: .init(rawValue: id), turnID: turn, generation: session.generation, kind: "approval", approval: .init(summary: summary, command: command, supportsAlwaysAllow: value["always"]?.arrayValue?.isEmpty == false), rawPayload: raw)
        pending[request.id] = .init(id: id, request: request, questionIndex: nil, questionCount: 0)
        try emit(.init(kind: .request, turnID: turn, request: request, rawPayload: raw))
    }

    private func questions(_ value: [String: ConversationJSONValue], turn: ConversationTurnID?, raw: ConversationJSONValue) throws {
        guard let id = value["id"]?.stringValue else { throw ConversationProviderError.malformed("OpenCode question has no identifier") }
        let questions = value["questions"]?.arrayValue ?? []
        for (index, question) in questions.enumerated() {
            guard let question = question.objectValue, let prompt = question["question"]?.stringValue else { throw ConversationProviderError.malformed("OpenCode question is incomplete") }
            let choices = (question["options"]?.arrayValue ?? []).compactMap { option -> ConversationQuestionOption? in
                guard let value = option.objectValue, let label = value["label"]?.stringValue else { return nil }
                return .init(id: label, label: label, detail: value["description"]?.stringValue)
            }
            let request = ConversationRequest(id: .init(rawValue: "\(id):\(index)"), turnID: turn, generation: session.generation, kind: "question", question: .init(category: question["header"]?.stringValue, prompt: prompt, options: choices, allowsCustomAnswer: question["custom"]?.boolValue != false, index: index, total: questions.count), rawPayload: raw)
            pending[request.id] = .init(id: id, request: request, questionIndex: index, questionCount: questions.count)
            try emit(.init(kind: .request, turnID: turn, request: request, rawPayload: raw))
        }
    }

    private func answer(_ id: ConversationRequestID, _ values: [ConversationQuestionAnswer]) async throws {
        guard let request = pending[id], let index = request.questionIndex, let answer = values.first(where: { $0.index == index }) ?? (values.count == 1 ? values.first : nil) else { throw ConversationProviderError.rejected("This question is no longer pending") }
        let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCustom = text?.isEmpty == false
        guard !isCustom || request.request.question?.allowsCustomAnswer == true,
              let value = isCustom ? text : answer.optionID, !value.isEmpty else { throw ConversationProviderError.rejected("Select an offered answer or enter a permitted custom answer") }
        if !isCustom, request.request.question?.options.contains(where: { $0.id == value }) != true { throw ConversationProviderError.rejected("The selected answer is not offered") }
        answers[request.id, default: [:]][index] = value
        if answers[request.id]?.count == request.questionCount {
            let ordered: [ConversationJSONValue] = (0..<request.questionCount).map { .array([.string(answers[request.id]?[$0] ?? "")]) }
            let accepted = try await call("question.reply", ["requestID": .string(request.id), "body": .object(["answers": .array(ordered)])])
            guard accepted == .bool(true) else { throw ConversationProviderError.rejected("OpenCode did not accept the answer") }
            answers.removeValue(forKey: request.id)
        }
        try resolve(request, state: .answered); pending.removeValue(forKey: id)
    }
    private func resolve(_ native: NativeRequest, state: ConversationRequestState) throws {
        var request = native.request; request.state = state
        try emit(.init(kind: .request, turnID: request.turnID, request: request))
    }
    private func emit(_ value: ConversationProviderEvent) throws {
        if case .dropped = continuation.yield(value) { throw ConversationProviderError.unavailable("OpenCode event buffer overflow") }
    }
    private func ended(_ error: any Error) async {
        guard !closed else { return }; continuation.finish(throwing: error); await close()
    }
    func close() async {
        guard !closed else { return }; closed = true
        reader?.cancel(); reader = nil; continuation.finish(); await transport.close()
    }
}
