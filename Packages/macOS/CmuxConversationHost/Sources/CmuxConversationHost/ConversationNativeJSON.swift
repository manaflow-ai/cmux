import CmuxConversation

extension ConversationJSONValue {
    var objectValue: [String: ConversationJSONValue]? { if case .object(let value) = self { value } else { nil } }
    var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    var numberValue: String? { if case .number(let value) = self { value } else { nil } }
    var stringOrNumber: String? { stringValue ?? numberValue }
}

/// Provider-specific JSON mapping rules with unknown payload preservation.
struct ConversationNativeEventMapper: Sendable {
    let provider: ConversationProvider

    func event(from payload: ConversationJSONValue) -> ConversationProviderEvent {
        guard let object = payload.objectValue else { return ConversationProviderEvent(kind: .unknown("non-object"), rawPayload: payload) }
        switch provider {
        case .codex: return codexEvent(object: object, raw: payload)
        case .claudeCode: return claudeEvent(object: object, raw: payload)
        case .openCode: return openCodeEvent(object: object, raw: payload)
        case .unknown: return ConversationProviderEvent(kind: .unknown("provider"), rawPayload: payload)
        }
    }

    func command(_ command: ConversationCommand) throws -> ConversationJSONValue {
        switch provider {
        case .codex: return try codexCommand(command)
        case .claudeCode: return try claudeCommand(command)
        case .openCode: return try openCodeCommand(command)
        case .unknown(let value): throw ConversationProviderError.unsupported("unknown provider \(value)")
        }
    }

    private func codexEvent(object: [String: ConversationJSONValue], raw: ConversationJSONValue) -> ConversationProviderEvent {
        let method = object["method"]?.stringValue ?? object["type"]?.stringValue ?? "unknown"
        let params = object["params"]?.objectValue ?? object
        let itemID = identifier(params["itemId"] ?? params["item_id"] ?? params["id"], as: ConversationItemID.init(rawValue:))
        let turnID = identifier(params["turnId"] ?? params["turn_id"] ?? params["turn"], as: ConversationTurnID.init(rawValue:))
        if method.contains("approval") || method.contains("requestApproval") { return ConversationProviderEvent(kind: .request, turnID: turnID, request: approvalRequest(params: params, turnID: turnID), rawPayload: raw) }
        if method.contains("question") || method.contains("askUser") { return ConversationProviderEvent(kind: .request, turnID: turnID, request: questionRequest(params: params, turnID: turnID), rawPayload: raw) }
        if method.contains("turn/started") || method.contains("turn.started") { return ConversationProviderEvent(kind: .turn, turnID: turnID, state: "running", rawPayload: raw) }
        if method.contains("turn/completed") || method.contains("turn.completed") || method.contains("turn/failed") { return ConversationProviderEvent(kind: .turn, turnID: turnID, state: method.contains("failed") ? "failed" : "completed", rawPayload: raw) }
        if method.contains("delta") || method.contains("agentMessage") {
            return ConversationProviderEvent(kind: .item, itemID: itemID, turnID: turnID, itemKind: .message, text: params["delta"]?.stringValue ?? params["text"]?.stringValue ?? params["content"]?.stringValue, rawPayload: raw)
        }
        if method.contains("commandExecution") || method.contains("tool") {
            let status: ConversationToolStatus = method.contains("completed") ? .success : (method.contains("failed") ? .failed : .running)
            let tool = ConversationTool(toolID: itemID?.rawValue ?? UUID().uuidString, name: params["name"]?.stringValue ?? "Tool", input: params["input"], output: params["output"], status: status)
            return ConversationProviderEvent(kind: .item, itemID: itemID, turnID: turnID, itemKind: .tool, tool: tool, rawPayload: raw)
        }
        if method.contains("plan") { return ConversationProviderEvent(kind: .item, itemID: itemID, turnID: turnID, itemKind: .plan, plan: ConversationPlan(text: params["text"]?.stringValue ?? params["plan"]?.stringValue ?? ""), rawPayload: raw) }
        if method.contains("diff") || method.contains("file") { return ConversationProviderEvent(kind: .item, itemID: itemID, turnID: turnID, itemKind: .files, diff: ConversationDiff(path: params["path"]?.stringValue ?? "", text: params["diff"]?.stringValue ?? ""), rawPayload: raw) }
        if method.contains("usage") { return ConversationProviderEvent(kind: .item, itemID: itemID, turnID: turnID, itemKind: .usage, usage: ConversationUsage(inputTokens: integer(params["inputTokens"]), outputTokens: integer(params["outputTokens"]), cachedTokens: integer(params["cachedTokens"]), model: params["model"]?.stringValue), rawPayload: raw) }
        return ConversationProviderEvent(kind: .unknown(method), state: params["status"]?.stringValue, rawPayload: raw)
    }

    private func claudeEvent(object: [String: ConversationJSONValue], raw: ConversationJSONValue) -> ConversationProviderEvent {
        let type = object["type"]?.stringValue ?? "unknown"
        let message = object["message"]?.objectValue ?? object
        let itemID = identifier(object["item_id"] ?? object["uuid"] ?? object["id"], as: ConversationItemID.init(rawValue:))
        let turnID = identifier(object["turn_id"] ?? object["session_id"], as: ConversationTurnID.init(rawValue:))
        if type == "result" { return ConversationProviderEvent(kind: .turn, turnID: turnID, state: object["is_error"]?.boolValue == true ? "failed" : "completed", text: object["result"]?.stringValue, rawPayload: raw) }
        if type == "control_request" { return ConversationProviderEvent(kind: .request, turnID: turnID, request: questionRequest(params: object, turnID: turnID), rawPayload: raw) }
        if type == "content_block_delta" || type == "assistant" || type == "message_delta" {
            let content = object["delta"]?.objectValue?["text"]?.stringValue ?? message["content"]?.stringValue ?? object["text"]?.stringValue
            return ConversationProviderEvent(kind: .item, itemID: itemID, turnID: turnID, itemKind: .message, text: content, rawPayload: raw)
        }
        if type == "tool_use" || type == "tool_result" { let tool = ConversationTool(toolID: object["id"]?.stringValue ?? itemID?.rawValue ?? UUID().uuidString, name: object["name"]?.stringValue ?? "Tool", input: object["input"], output: object["content"], status: type == "tool_result" ? .success : .running); return ConversationProviderEvent(kind: .item, itemID: itemID, turnID: turnID, itemKind: .tool, tool: tool, rawPayload: raw) }
        if type == "system" { return ConversationProviderEvent(kind: .run, turnID: turnID, state: object["subtype"]?.stringValue, rawPayload: raw) }
        return ConversationProviderEvent(kind: .unknown(type), rawPayload: raw)
    }

    private func openCodeEvent(object: [String: ConversationJSONValue], raw: ConversationJSONValue) -> ConversationProviderEvent {
        let type = object["type"]?.stringValue ?? object["event"]?.stringValue ?? "unknown"
        let properties = object["properties"]?.objectValue ?? object["data"]?.objectValue ?? object
        let itemID = identifier(properties["partID"] ?? properties["part_id"] ?? properties["id"], as: ConversationItemID.init(rawValue:))
        let turnID = identifier(properties["sessionID"] ?? properties["session_id"], as: ConversationTurnID.init(rawValue:))
        if type.contains("status") { return ConversationProviderEvent(kind: .run, turnID: turnID, state: properties["status"]?.stringValue, rawPayload: raw) }
        if type.contains("permission") || type.contains("question") { return ConversationProviderEvent(kind: .request, turnID: turnID, request: questionRequest(params: properties, turnID: turnID), rawPayload: raw) }
        if type.contains("part") || type.contains("message") { return ConversationProviderEvent(kind: .item, itemID: itemID, turnID: turnID, itemKind: properties["tool"] != nil ? .tool : .message, text: properties["text"]?.stringValue ?? properties["content"]?.stringValue, rawPayload: raw) }
        return ConversationProviderEvent(kind: .unknown(type), rawPayload: raw)
    }

    private func approvalRequest(params: [String: ConversationJSONValue], turnID: ConversationTurnID?) -> ConversationRequest {
        let id = identifier(params["requestID"] ?? params["request_id"] ?? params["id"], as: ConversationRequestID.init(rawValue:)) ?? ConversationRequestID(rawValue: UUID().uuidString)
        return ConversationRequest(id: id, turnID: turnID, generation: "provider", kind: "approval", approval: ConversationApproval(summary: params["summary"]?.stringValue ?? params["description"]?.stringValue ?? "Approval required", command: params["command"]?.stringValue, supportsAlwaysAllow: params["supportsAlwaysAllow"]?.boolValue ?? false), rawPayload: .object(params))
    }

    private func questionRequest(params: [String: ConversationJSONValue], turnID: ConversationTurnID?) -> ConversationRequest {
        let id = identifier(params["requestID"] ?? params["request_id"] ?? params["id"], as: ConversationRequestID.init(rawValue:)) ?? ConversationRequestID(rawValue: UUID().uuidString)
        return ConversationRequest(id: id, turnID: turnID, generation: "provider", kind: "question", question: ConversationQuestion(category: params["category"]?.stringValue, prompt: params["question"]?.stringValue ?? params["prompt"]?.stringValue ?? "Input required"), rawPayload: .object(params))
    }

    private func identifier<T>(_ value: ConversationJSONValue?, as make: (String) -> T) -> T? { guard let raw = value?.stringOrNumber, !raw.isEmpty else { return nil }; return make(raw) }
    private func integer(_ value: ConversationJSONValue?) -> Int64? { guard let raw = value?.stringOrNumber else { return nil }; return Int64(raw) }

    private func codexCommand(_ command: ConversationCommand) throws -> ConversationJSONValue {
        switch command {
        case .startTurn(let text, let model, let effort): return .object(["jsonrpc": .string("2.0"), "id": .string(UUID().uuidString), "method": .string("turn/start"), "params": .object(["input": .array([.object(["type": .string("text"), "text": .string(text)])]), "model": model.map(ConversationJSONValue.string) ?? .null, "effort": effort.map(ConversationJSONValue.string) ?? .null])])
        case .steer(let text): return .object(["jsonrpc": .string("2.0"), "id": .string(UUID().uuidString), "method": .string("turn/steer"), "params": .object(["input": .array([.object(["type": .string("text"), "text": .string(text)])])])])
        case .interrupt: return .object(["jsonrpc": .string("2.0"), "id": .string(UUID().uuidString), "method": .string("turn/interrupt"), "params": .object([:])])
        case .queue, .editQueued, .cancelQueued: throw ConversationProviderError.rejected("Codex queue is broker-owned")
        case .answerQuestion, .resolveApproval: throw ConversationProviderError.unsupported("Codex request response requires native request identifier context")
        case .rename, .setPinned, .setArchived, .configure: throw ConversationProviderError.rejected("metadata command is broker-owned")
        }
    }

    private func claudeCommand(_ command: ConversationCommand) throws -> ConversationJSONValue {
        switch command {
        case .startTurn(let text, _, _), .steer(let text): return .object(["type": .string("user"), "message": .object(["role": .string("user"), "content": .string(text)])])
        case .interrupt: return .object(["type": .string("control_request"), "request_id": .string(UUID().uuidString), "request": .object(["subtype": .string("interrupt")])])
        case .answerQuestion, .resolveApproval: throw ConversationProviderError.unsupported("Claude request response requires native control request context")
        case .queue, .editQueued, .cancelQueued: throw ConversationProviderError.rejected("Claude queue is broker-owned")
        case .rename, .setPinned, .setArchived, .configure: throw ConversationProviderError.rejected("metadata command is broker-owned")
        }
    }

    private func openCodeCommand(_ command: ConversationCommand) throws -> ConversationJSONValue {
        switch command {
        case .startTurn(let text, let model, let effort): return .object(["method": .string("session.prompt"), "params": .object(["parts": .array([.object(["type": .string("text"), "text": .string(text)])]), "model": model.map(ConversationJSONValue.string) ?? .null, "effort": effort.map(ConversationJSONValue.string) ?? .null])])
        case .steer(let text): return .object(["method": .string("session.prompt"), "params": .object(["parts": .array([.object(["type": .string("text"), "text": .string(text)])])])])
        case .interrupt: return .object(["method": .string("session.abort"), "params": .object([:])])
        case .answerQuestion, .resolveApproval: throw ConversationProviderError.unsupported("OpenCode request response endpoint is version-dependent")
        case .queue, .editQueued, .cancelQueued: throw ConversationProviderError.rejected("OpenCode queue is broker-owned")
        case .rename, .setPinned, .setArchived, .configure: throw ConversationProviderError.rejected("metadata command is broker-owned")
        }
    }
}
