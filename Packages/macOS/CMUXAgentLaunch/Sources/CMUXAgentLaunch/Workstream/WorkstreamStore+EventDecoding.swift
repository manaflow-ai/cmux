import Foundation

// Event-to-item payload decoding owned by the store.
extension WorkstreamStore {
    func decode(
        event: WorkstreamEvent,
        source: WorkstreamSource
    ) -> (WorkstreamKind, WorkstreamPayload) {
        let toolInput = event.toolInputJSON ?? "{}"
        switch event.hookEventName {
        case .permissionRequest:
            return (
                .permissionRequest,
                .permissionRequest(
                    requestId: event.requestId ?? event.sessionId,
                    toolName: event.toolName ?? "unknown",
                    toolInputJSON: toolInput,
                    pattern: nil
                )
            )
        case .askUserQuestion:
            let parsed = WorkstreamQuestionPrompt.parse(toolInputJSON: event.toolInputJSON)
            return (
                .question,
                .question(
                    requestId: event.requestId ?? event.sessionId,
                    questions: parsed
                )
            )
        case .exitPlanMode:
            return (
                .exitPlan,
                .exitPlan(
                    requestId: event.requestId ?? event.sessionId,
                    plan: toolInput,
                    defaultMode: .manual
                )
            )
        case .preToolUse:
            return (.toolUse, .toolUse(toolName: event.toolName ?? "", toolInputJSON: toolInput))
        case .postToolUse:
            return (
                .toolResult,
                .toolResult(toolName: event.toolName ?? "", resultJSON: toolInput, isError: event.isError ?? false)
            )
        case .postToolUseFailure:
            return (
                .toolResult,
                .toolResult(toolName: event.toolName ?? "", resultJSON: toolInput, isError: true)
            )
        case .preCompact:
            return (.toolUse, .toolUse(toolName: titleProvider(event) ?? event.hookEventName.rawValue, toolInputJSON: toolInput))
        case .postCompact:
            return (
                .toolResult,
                .toolResult(toolName: titleProvider(event) ?? event.hookEventName.rawValue, resultJSON: toolInput, isError: false)
            )
        case .subagentStart:
            return (.toolUse, .toolUse(toolName: titleProvider(event) ?? event.hookEventName.rawValue, toolInputJSON: toolInput))
        case .subagentStop:
            return (
                .toolResult,
                .toolResult(toolName: titleProvider(event) ?? event.hookEventName.rawValue, resultJSON: toolInput, isError: false)
            )
        case .userPromptSubmit:
            let prompt = Self.promptText(from: event.toolInputJSON)
            return (
                .userPrompt,
                .userPrompt(text: prompt.isEmpty ? (event.context?.lastUserMessage ?? "") : prompt)
            )
        case .sessionStart:
            return (.sessionStart, .sessionStart)
        case .sessionEnd:
            return (.sessionEnd, .sessionEnd)
        case .stop:
            return (.stop, .stop(reason: Self.stopReason(from: event.toolInputJSON)))
        case .todoWrite:
            return (.todos, .todos(Self.todos(from: event.toolInputJSON)))
        case .notification:
            return (.toolResult, .toolResult(toolName: "notification", resultJSON: toolInput, isError: false))
        }
    }

    func defaultTitle(for event: WorkstreamEvent) -> String? {
        if let tool = event.toolName, !tool.isEmpty {
            return tool
        }
        return titleProvider(event)
    }

    private static func jsonObject(from json: String?) -> Any? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func promptText(from json: String?) -> String {
        if let dict = jsonObject(from: json) as? [String: Any] {
            return (dict["prompt"] as? String)
                ?? (dict["text"] as? String)
                ?? (dict["message"] as? String)
                ?? ""
        }
        return json ?? ""
    }

    private static func stopReason(from json: String?) -> String? {
        if let dict = jsonObject(from: json) as? [String: Any] {
            return (dict["reason"] as? String)
                ?? (dict["message"] as? String)
                ?? (dict["cause"] as? String)
        }
        return nil
    }

    private static func todos(from json: String?) -> [WorkstreamTaskTodo] {
        let rawTodos: [Any]
        if let dict = jsonObject(from: json) as? [String: Any] {
            rawTodos = dict["todos"] as? [Any] ?? []
        } else {
            rawTodos = jsonObject(from: json) as? [Any] ?? []
        }
        return rawTodos.enumerated().compactMap { idx, raw in
            guard let dict = raw as? [String: Any] else { return nil }
            let content = (dict["content"] as? String)
                ?? (dict["text"] as? String)
                ?? (dict["title"] as? String)
                ?? ""
            guard !content.isEmpty else { return nil }
            let rawState = (dict["state"] as? String)
                ?? (dict["status"] as? String)
                ?? "pending"
            let state: WorkstreamTaskTodo.State
            switch rawState {
            case "completed", "done":
                state = .completed
            case "inProgress", "in_progress", "active":
                state = .inProgress
            default:
                state = .pending
            }
            return WorkstreamTaskTodo(
                id: (dict["id"] as? String) ?? "todo\(idx)",
                content: content,
                state: state
            )
        }
    }
}
