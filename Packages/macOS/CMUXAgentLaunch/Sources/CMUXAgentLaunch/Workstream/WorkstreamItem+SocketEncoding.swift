import Foundation

extension WorkstreamItem {
    /// The `[String: Any]` JSON shape the `feed.*` socket handlers emit for one
    /// feed item. Byte-faithful port of the legacy `FeedSocketEncoding.itemDict`.
    ///
    /// - Parameter codexCapabilityToolInputJSON: Resolver that distills a Codex
    ///   permission request's raw tool-input JSON into the capability snapshot
    ///   emitted under `tool_input_capabilities`. The app injects
    ///   `FeedPermissionActionPolicy.codexCapabilityToolInputJSON`, keeping the
    ///   permission-mode policy logic app-side.
    public func socketEncodedDictionary(
        codexCapabilityToolInputJSON: (WorkstreamSource, String) -> String?
    ) -> [String: Any] {
        let isoFormatter = ISO8601DateFormatter()
        var dict: [String: Any] = [
            "id": id.uuidString,
            "workstream_id": workstreamId,
            "source": source.rawValue,
            "kind": kind.rawValue,
            "created_at": isoFormatter.string(from: createdAt),
            "updated_at": isoFormatter.string(from: updatedAt),
        ]
        if let cwd { dict["cwd"] = cwd }
        if let title { dict["title"] = title }
        switch status {
        case .pending:
            dict["status"] = "pending"
        case .resolved(let decision, let at):
            dict["status"] = "resolved"
            dict["decision"] = decision.socketEncodedDictionary
            dict["resolved_at"] = isoFormatter.string(from: at)
        case .expired(let at):
            dict["status"] = "expired"
            dict["resolved_at"] = isoFormatter.string(from: at)
        case .telemetry:
            dict["status"] = "telemetry"
        }
        switch payload {
        case .permissionRequest(let requestId, let toolName, let toolInputJSON, let pattern):
            dict["request_id"] = requestId
            dict["tool_name"] = toolName
            if let capabilityJSON = codexCapabilityToolInputJSON(source, toolInputJSON) {
                dict["tool_input_capabilities"] = capabilityJSON
            }
            dict.assignFeedSocketTruncated(toolInputJSON, key: "tool_input")
            if let pattern { dict["pattern"] = pattern }
        case .exitPlan(let requestId, let plan, let defaultMode):
            dict["request_id"] = requestId
            dict.assignFeedSocketTruncated(plan, key: "plan")
            dict["plan_summary"] = plan.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            dict["default_mode"] = defaultMode.rawValue
        case .question(let requestId, let questions):
            dict["request_id"] = requestId
            dict["questions"] = questions.map { $0.socketEncodedDictionary }
            if let firstQuestion = questions.first {
                dict.assignFeedSocketTruncated(firstQuestion.prompt, key: "question_prompt")
                dict["question_multi_select"] = firstQuestion.multiSelect
                dict["question_options"] = firstQuestion.options.map { option in
                    var optionDict: [String: Any] = [
                        "id": option.id,
                        "label": option.label.feedSocketTruncated(limit: String.feedSocketSecondaryTextLimit).text,
                    ]
                    if let description = option.description {
                        optionDict.assignFeedSocketTruncated(description, key: "description", limit: String.feedSocketSecondaryTextLimit)
                    }
                    return optionDict
                }
            }
        case .toolUse(let toolName, let toolInputJSON):
            dict["tool_name"] = toolName
            dict.assignFeedSocketTruncated(toolInputJSON, key: "tool_input")
        case .toolResult(let toolName, let resultJSON, let isError):
            dict["tool_name"] = toolName
            dict.assignFeedSocketTruncated(resultJSON, key: "tool_result")
            dict["tool_result_is_error"] = isError
        case .userPrompt(let text), .assistantMessage(let text):
            dict.assignFeedSocketTruncated(text, key: "text")
        case .sessionStart, .sessionEnd:
            break
        case .stop(let reason):
            if let reason { dict.assignFeedSocketTruncated(reason, key: "reason", limit: String.feedSocketSecondaryTextLimit) }
        case .todos(let todos):
            dict["todos"] = todos.map { todo in
                [
                    "id": todo.id,
                    "content": todo.content.feedSocketTruncated(limit: String.feedSocketSecondaryTextLimit).text,
                    "state": todo.state.rawValue,
                ]
            }
        }
        return dict
    }
}
