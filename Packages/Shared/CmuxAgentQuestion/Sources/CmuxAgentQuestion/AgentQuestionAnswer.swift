public import Foundation

/// A person's answer to an `AgentQuestion`, harness-neutral: one selection
/// per item, plus who answered and from which device.
public struct AgentQuestionAnswer: Hashable, Sendable, Codable {
    /// Item id -> what was chosen for it.
    public var selections: [String: Selection]
    public var respondent: Respondent?
    /// Milliseconds since 1970 (the owners' clock unit), stamped by the owner.
    public var answeredAtMs: Int64?

    public init(selections: [String: Selection], respondent: Respondent? = nil, answeredAtMs: Int64? = nil) {
        self.selections = selections
        self.respondent = respondent
        self.answeredAtMs = answeredAtMs
    }

    public struct Selection: Hashable, Sendable, Codable {
        /// Option ids in the order the item lists them.
        public var optionIDs: [String]
        /// Free text typed into "Other", trimmed; nil when empty.
        public var other: String?

        public init(optionIDs: [String] = [], other: String? = nil) {
            self.optionIDs = optionIDs
            let trimmed = other?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.other = trimmed?.isEmpty == false ? trimmed : nil
        }

        public var isEmpty: Bool { optionIDs.isEmpty && other == nil }
    }

    /// Who answered. The owner stamps it from the connection, never from
    /// the client's claim.
    public struct Respondent: Hashable, Sendable, Codable {
        /// Conversation participant (`user_local`, `user_<id>`).
        public var participant: String?
        public var displayName: String?
        /// The answering device's name ("Lawrence's iPhone").
        public var device: String?
        /// True when the answer came through the remote relay from a paired device.
        public var isRemote: Bool

        public init(participant: String? = nil, displayName: String? = nil, device: String? = nil, isRemote: Bool = false) {
            self.participant = participant
            self.displayName = displayName
            self.device = device
            self.isRemote = isRemote
        }
    }

    /// Why an answer cannot be sent.
    public enum Problem: Hashable, Sendable, Error {
        case unanswered(item: String)
        case tooManyChoices(item: String)
        case unknownOption(item: String, option: String)
        case otherNotAllowed(item: String)
        case unknownItem(String)
        case notPending
    }

    /// Checks the answer against its question. An item is answered by
    /// exactly one option or Other text (single select), or by one or more
    /// options plus optional Other text (multi-select).
    public func problems(for question: AgentQuestion) -> [Problem] {
        guard question.isPending else { return [.notPending] }
        var problems: [Problem] = selections.keys.filter { key in !question.items.contains { $0.id == key } }.sorted().map(Problem.unknownItem)
        for item in question.items {
            let selection = selections[item.id] ?? Selection()
            if selection.isEmpty { problems.append(.unanswered(item: item.id)); continue }
            for option in selection.optionIDs where !item.options.contains(where: { $0.id == option }) {
                problems.append(.unknownOption(item: item.id, option: option))
            }
            if selection.other != nil, !item.allowsOther { problems.append(.otherNotAllowed(item: item.id)) }
            if !item.multiSelect, selection.optionIDs.count + (selection.other == nil ? 0 : 1) > 1 {
                problems.append(.tooManyChoices(item: item.id))
            }
        }
        return problems
    }
}

/// What a client sends to `_acpmux/permission_respond` to answer a question.
public struct AgentQuestionReply: Hashable, Sendable {
    public var session: String
    public var permissionId: String
    /// nil cancels the request.
    public var optionId: String?
    /// The harness-shaped answers acpmux puts into the tool's input.
    public var answers: AgentQuestionJSON?

    /// The `_acpmux/permission_respond` params.
    public var params: AgentQuestionJSON {
        var object: [String: AgentQuestionJSON] = ["sessionId": .string(session), "permissionId": .string(permissionId)]
        if let optionId { object["optionId"] = .string(optionId) }
        if let answers { object["answers"] = answers }
        return .object(object)
    }
}

extension AgentQuestion {
    /// The reply that submits `answer`, in the asking harness's shape.
    /// Throws the first problem when the answer is incomplete or invalid.
    public func reply(_ answer: AgentQuestionAnswer) throws -> AgentQuestionReply {
        if let problem = answer.problems(for: self).first { throw problem }
        guard let permission = source.permission else { throw AgentQuestionAnswer.Problem.notPending }
        switch source.harness {
        case .acp:
            // One item; its option ids are the permission options.
            let optionId = answer.selections[items[0].id]?.optionIDs.first
            return AgentQuestionReply(session: source.session, permissionId: permission, optionId: optionId, answers: nil)
        case .claude, .chief:
            // Claude Code reads `answers` keyed by question text; several
            // choices are one comma-separated string.
            var answers: [String: AgentQuestionJSON] = [:]
            for item in items {
                answers[item.prompt] = .string(labels(item, answer.selections[item.id]).joined(separator: ", "))
            }
            return AgentQuestionReply(session: source.session, permissionId: permission, optionId: source.answerOption ?? "allow_once",
                                      answers: .object(answers))
        case .codex:
            // Codex reads `{id: {answers: [String]}}`.
            var answers: [String: AgentQuestionJSON] = [:]
            for item in items {
                answers[item.id] = ["answers": .array(labels(item, answer.selections[item.id]).map(AgentQuestionJSON.string))]
            }
            return AgentQuestionReply(session: source.session, permissionId: permission, optionId: source.answerOption ?? "allow_once",
                                      answers: .object(answers))
        }
    }

    /// The reply that declines the question: the harness's reject option,
    /// else a cancel. Never an allow.
    public func declineReply() -> AgentQuestionReply? {
        guard let permission = source.permission else { return nil }
        return AgentQuestionReply(session: source.session, permissionId: permission, optionId: source.rejectOption, answers: nil)
    }

    /// The chosen option labels, then the Other text.
    func labels(_ item: Item, _ selection: AgentQuestionAnswer.Selection?) -> [String] {
        guard let selection else { return [] }
        let chosen = item.options.filter { selection.optionIDs.contains($0.id) }.map(\.label)
        return chosen + [selection.other].compactMap { $0 }
    }

    /// One line per item for the answered card and notifications:
    /// "Auth method: OAuth, Passkeys".
    public func summaryLines(_ answer: AgentQuestionAnswer) -> [String] {
        items.map { item in
            let value = labels(item, answer.selections[item.id]).joined(separator: ", ")
            return "\(item.header ?? item.prompt): \(value)"
        }
    }
}

extension AgentQuestion {
    /// The question answered with `answer`, as an owner commits it: the
    /// answer must be valid (`problems`), the respondent and time come from
    /// the owner. Option ids keep the items' order.
    public func answering(_ answer: AgentQuestionAnswer, respondent: AgentQuestionAnswer.Respondent?, atMs: Int64?) throws -> AgentQuestion {
        if let problem = answer.problems(for: self).first { throw problem }
        var selections: [String: AgentQuestionAnswer.Selection] = [:]
        for item in items {
            let chosen = answer.selections[item.id] ?? .init()
            let ids = item.options.map(\.id).filter { chosen.optionIDs.contains($0) }
            selections[item.id] = AgentQuestionAnswer.Selection(optionIDs: ids, other: chosen.other)
        }
        var answered = self
        answered.state = .answered(AgentQuestionAnswer(selections: selections, respondent: respondent, answeredAtMs: atMs))
        return answered
    }
}
