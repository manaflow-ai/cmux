import Foundation

// Internal only because `WorkstreamStore.swift` calls these helpers across the
// file split; treat them as WorkstreamStore implementation details.
extension WorkstreamStore {
    /// Parses question tool input into one or more prompts.
    func parseQuestions(fromToolInput json: String?) -> [WorkstreamQuestionPrompt] {
        guard let json, let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        if let arr = root["questions"] as? [[String: Any]] {
            return arr.enumerated().map { idx, q in
                Self.makeQuestion(from: q, fallbackId: "q\(idx)")
            }
        }
        return [Self.makeQuestion(from: root, fallbackId: "q0")]
    }

    static func makeQuestion(from dict: [String: Any], fallbackId: String) -> WorkstreamQuestionPrompt {
        let header = (dict["header"] as? String)
            ?? (dict["title"] as? String)
        let prompt = (dict["question"] as? String)
            ?? (dict["prompt"] as? String)
            ?? ""
        let multi = (dict["multiSelect"] as? Bool)
            ?? (dict["multi_select"] as? Bool)
            ?? false
        let rawOptions = dict["options"] as? [Any] ?? []
        var options: [WorkstreamQuestionOption] = []
        for (i, raw) in rawOptions.enumerated() {
            if let s = raw as? String {
                options.append(WorkstreamQuestionOption(id: "opt\(i)", label: s))
            } else if let d = raw as? [String: Any] {
                let id = (d["id"] as? String) ?? "opt\(i)"
                let label = (d["label"] as? String) ?? (d["title"] as? String) ?? id
                let description = (d["description"] as? String) ?? (d["detail"] as? String)
                options.append(WorkstreamQuestionOption(
                    id: id, label: label, description: description
                ))
            }
        }
        return WorkstreamQuestionPrompt(
            id: (dict["id"] as? String) ?? fallbackId,
            header: header,
            prompt: prompt,
            multiSelect: multi,
            options: options
        )
    }

    static func jsonObject(from json: String?) -> Any? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func promptText(from json: String?) -> String {
        if let dict = jsonObject(from: json) as? [String: Any] {
            return (dict["prompt"] as? String)
                ?? (dict["text"] as? String)
                ?? (dict["message"] as? String)
                ?? ""
        }
        return json ?? ""
    }

    static func carriedContext(from context: WorkstreamContext) -> WorkstreamContext? {
        let carried = WorkstreamContext(
            lastUserMessage: context.lastUserMessage,
            assistantPreamble: context.assistantPreamble,
            permissionMode: context.permissionMode
        )
        return carried.isEmpty ? nil : carried
    }

    static func stopReason(from json: String?) -> String? {
        if let dict = jsonObject(from: json) as? [String: Any] {
            return (dict["reason"] as? String)
                ?? (dict["message"] as? String)
                ?? (dict["cause"] as? String)
        }
        return nil
    }

    static func todos(from json: String?) -> [WorkstreamTaskTodo] {
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
