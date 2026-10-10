public import Foundation

extension AgentQuestion {
    /// Maps an acpmux `permission_request` record (the ACP
    /// `session/request_permission` params plus acpmux's permission id) to a
    /// question, or nil when the request is an ordinary tool permission.
    ///
    /// Precedence: the daemon's normalized `toolCall._meta.acpmux.question`
    /// when present, then Claude Code's AskUserQuestion input, then a Codex
    /// user-input request, then any request marked interactive (its
    /// permission options become the choices).
    public init?(permissionRequest request: AgentQuestionJSON, permissionId: String, session: String) {
        let toolCall = request["toolCall"] ?? .null
        let input = toolCall["rawInput"] ?? .null
        let options = Self.permissionOptions(request)
        let answerOption = options.first { $0.kind == "allow_once" }?.id
        let rejectOption = options.first { $0.kind == "reject_once" }?.id
        var source = Source(harness: .acp, session: session, permission: permissionId, toolCall: toolCall["toolCallId"]?.string)
        source.answerOption = answerOption
        source.rejectOption = rejectOption

        if let normalized = toolCall.at("_meta/acpmux/question"), let items = Self.normalizedItems(normalized), !items.isEmpty {
            source.harness = normalized["harness"]?.string.flatMap(Harness.init(rawValue:)) ?? .acp
            source.agentName = normalized["agent"]?.text
            self.init(id: permissionId, source: source, items: items)
            return
        }
        let claudeTool = toolCall.at("_meta/claude/tool")?.string
        let questions = input["questions"]?.array ?? []
        let isCodex = toolCall.at("_meta/codex") != nil || questions.contains { $0["id"]?.text != nil }
        if claudeTool == "AskUserQuestion" || (!questions.isEmpty && !isCodex) {
            let items = questions.enumerated().compactMap { Self.claudeItem($1, index: $0) }
            guard !items.isEmpty else { return nil }
            source.harness = .claude
            source.agentName = "Claude Code"
            self.init(id: permissionId, source: source, items: items)
            return
        }
        if isCodex {
            let items = questions.enumerated().compactMap { Self.codexItem($1, index: $0) }
            guard !items.isEmpty else { return nil }
            source.harness = .codex
            source.agentName = "Codex"
            self.init(id: permissionId, source: source, items: items)
            return
        }
        let interactive = toolCall.at("_meta/acpmux/interactive")?.bool == true || toolCall.at("_meta/claude/interactive")?.bool == true
        guard interactive, !options.isEmpty else { return nil }
        let prompt = toolCall["title"]?.text ?? ""
        let choices = options.map { Option(id: $0.id, label: $0.name) }
        self.init(id: permissionId, source: source, items: [Item(id: "q0", prompt: prompt, options: choices, allowsOther: false)])
    }

    struct PermissionOption {
        var id: String
        var name: String
        var kind: String?
    }

    static func permissionOptions(_ request: AgentQuestionJSON) -> [PermissionOption] {
        (request["options"]?.array ?? []).compactMap { option in
            guard let id = option["optionId"]?.text else { return nil }
            return PermissionOption(id: id, name: option["name"]?.text ?? id, kind: option["kind"]?.string)
        }
    }

    /// Claude Code: `{question, header, options: [{label, description, preview}], multiSelect}`.
    /// Answers are keyed by question text, so items keep positional ids.
    static func claudeItem(_ value: AgentQuestionJSON, index: Int) -> Item? {
        // The prompt keeps its exact text: Claude Code matches answers by it.
        guard value["question"]?.text != nil, let prompt = value["question"]?.string else { return nil }
        let options = uniqueOptions((value["options"]?.array ?? []).compactMap { option -> Option? in
            guard let label = option["label"]?.text else { return nil }
            let preview = option["preview"]?.text.map { Preview(text: $0, format: .monospace) }
            return Option(id: label, label: label, detail: option["description"]?.text, preview: preview)
        })
        return Item(id: "q\(index)", header: value["header"]?.text, prompt: prompt, options: options,
                    multiSelect: value["multiSelect"]?.bool ?? false, allowsOther: true)
    }

    /// Codex: `{id, header, question, isOther, options: [{label, description}] | null}`.
    /// Answers are keyed by `id`; a question with no options takes free text.
    static func codexItem(_ value: AgentQuestionJSON, index: Int) -> Item? {
        guard let prompt = value["question"]?.text else { return nil }
        let options = uniqueOptions((value["options"]?.array ?? []).compactMap { option -> Option? in
            guard let label = option["label"]?.text else { return nil }
            return Option(id: label, label: label, detail: option["description"]?.text)
        })
        let allowsOther = value["isOther"]?.bool ?? options.isEmpty
        return Item(id: value["id"]?.text ?? "q\(index)", header: value["header"]?.text, prompt: prompt, options: options,
                    multiSelect: value["multiSelect"]?.bool ?? false, allowsOther: allowsOther || options.isEmpty)
    }

    /// The daemon's normalized shape: `{harness, agent, items: [Item]}` with
    /// `Item` encoded as this package's Codable form.
    static func normalizedItems(_ value: AgentQuestionJSON) -> [Item]? {
        guard let items = value["items"], let data = try? items.data() else { return nil }
        return try? JSONDecoder().decode([Item].self, from: data)
    }

    /// Option ids must be unique within an item: a repeated label gets `#2`, `#3`.
    static func uniqueOptions(_ options: [Option]) -> [Option] {
        var seen: [String: Int] = [:]
        return options.map { option in
            var option = option
            let count = (seen[option.id] ?? 0) + 1
            seen[option.id] = count
            if count > 1 { option.id += "#\(count)" }
            return option
        }
    }
}
