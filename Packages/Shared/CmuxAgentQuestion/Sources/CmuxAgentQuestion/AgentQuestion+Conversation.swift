public import Foundation

/// The conversation owner's `question` part (snake_case, cmux-tui
/// spec/commands.md `Question`) and the `question.answer` op's `answer`.
extension AgentQuestion {
    /// Reads a stored `question` part. `id` is the part's address in the
    /// conversation (`<message id>#<part index>`), which stays stable while
    /// the owner moves the part from pending to answered.
    public init?(conversationPart part: AgentQuestionJSON, messageID: String, partIndex: Int) {
        guard let session = part["session"]?.text, let items = part["items"]?.array else { return nil }
        let mapped = items.compactMap { item -> Item? in
            guard let id = item["id"]?.text, let prompt = item["prompt"]?.text else { return nil }
            let options = (item["options"]?.array ?? []).compactMap { option -> Option? in
                guard let id = option["id"]?.text, let label = option["label"]?.text else { return nil }
                let preview = option["preview"].flatMap { preview -> Preview? in
                    guard let text = preview["text"]?.string else { return nil }
                    return Preview(text: text, format: preview["format"]?.string == "markdown" ? .markdown : .monospace)
                }
                return Option(id: id, label: label, detail: option["detail"]?.text, preview: preview)
            }
            return Item(id: id, header: item["header"]?.text, prompt: prompt, options: options,
                        multiSelect: item["multi_select"]?.bool ?? false, allowsOther: item["allows_other"]?.bool ?? true)
        }
        guard !mapped.isEmpty else { return nil }
        let harness = part["harness"]?.string.flatMap(Harness.init(rawValue:)) ?? .chief
        let source = Source(harness: harness, session: session, permission: part["permission"]?.text,
                            agentName: part["agent"]?.text)
        self.init(id: "\(messageID)#\(partIndex)", source: source, items: mapped, state: Self.conversationState(part["state"]))
    }

    static func conversationState(_ state: AgentQuestionJSON?) -> State {
        switch state?["kind"]?.string {
        case "cancelled": return .cancelled
        case "answered":
            let answer = state?["answer"] ?? .null
            var selections: [String: AgentQuestionAnswer.Selection] = [:]
            for (item, selection) in answer["selections"]?.object ?? [:] {
                let ids = (selection["option_ids"]?.array ?? []).compactMap(\.string)
                selections[item] = AgentQuestionAnswer.Selection(optionIDs: ids, other: selection["other"]?.string)
            }
            let respondent = answer["respondent"].map { value in
                AgentQuestionAnswer.Respondent(participant: value["participant"]?.string, displayName: value["display_name"]?.string,
                                               device: value["device"]?.string, isRemote: value["remote"]?.bool ?? false)
            }
            let millis = answer["answered_at"]?.string.flatMap(Self.millis)
            return .answered(AgentQuestionAnswer(selections: selections, respondent: respondent, answeredAtMs: millis))
        default: return .pending
        }
    }

    /// RFC 3339 with milliseconds (the owner's clock format) as milliseconds since 1970.
    static func millis(_ text: String) -> Int64? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text).map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }
}

extension AgentQuestionAnswer {
    /// The `answer` of a `question.answer` op: selections only; the owner
    /// stamps the respondent and the time.
    public var conversationAnswer: AgentQuestionJSON {
        var selections: [String: AgentQuestionJSON] = [:]
        for (item, selection) in self.selections {
            var value: [String: AgentQuestionJSON] = ["option_ids": .array(selection.optionIDs.map(AgentQuestionJSON.string))]
            if let other = selection.other { value["other"] = .string(other) }
            selections[item] = .object(value)
        }
        return ["selections": .object(selections)]
    }
}
