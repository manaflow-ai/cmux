public import CmuxAgentQuestion
public import Foundation

/// A question an agent asks in its chat (Claude Code's AskUserQuestion, a Codex
/// `request_user_input`), as a feed `choice` request the person answers inline,
/// in the Mac's feed or on the phone.
///
/// The feed owner bounds a choice (backend `feed-kinds.ts`): one to four
/// questions of two to eight options, ids of at most 40 characters, a header of
/// 40, a question of 1000, a label of 200, a description of 1000. A question's
/// own ids can be its text (Claude keys answers by question text), so the feed
/// sees positional ids (`q0`, `o0`) and an answer maps back by position onto the
/// same request. A question outside those bounds is not a choice.
public nonisolated struct AgentQuestionFeedChoice: Equatable, Sendable {
    public let question: AgentQuestion

    public static let maxQuestions = 4
    public static let optionRange = 2...8

    /// The question in an acpmux `session/request_permission` body, when it fits
    /// a feed choice. A plain ACP permission dressed as a question (`.acp`: its
    /// options are permission options) is never one.
    public init?(request: [String: Any], session: String, permission: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let json = try? AgentQuestionJSON(data: data),
              let question = AgentQuestion(permissionRequest: json, permissionId: permission, session: session),
              question.source.harness != .acp,
              (1...Self.maxQuestions).contains(question.items.count),
              question.items.allSatisfy({ Self.optionRange.contains($0.options.count) && !$0.prompt.isEmpty })
        else { return nil }
        self.question = question
    }

    /// The feed `choice` prompt (`{questions: [{id, question, header?, options, multi, allow_other}]}`).
    /// `clean` makes agent text fit to show (secret shapes scrubbed, invisible characters dropped).
    public func prompt(clean: (String) -> String) -> [String: Any] {
        ["questions": question.items.enumerated().map { index, item -> [String: Any] in
            var out: [String: Any] = [
                "id": "q\(index)",
                "question": Self.cut(clean(item.prompt), 1000),
                "options": item.options.enumerated().map { optionIndex, option -> [String: Any] in
                    var out: [String: Any] = ["id": "o\(optionIndex)", "label": Self.cut(clean(option.label), 200)]
                    if let detail = option.detail.map(clean), !detail.isEmpty { out["description"] = Self.cut(detail, 1000) }
                    return out
                },
                "multi": item.multiSelect,
                "allow_other": item.allowsOther,
            ]
            if let header = item.header.map(clean), !header.isEmpty { out["header"] = Self.cut(header, 40) }
            return out
        }]
    }

    /// What the card shows above its controls: every question, whole, with its options.
    public func body(clean: (String) -> String) -> String {
        let text = question.items.map { item -> String in
            var lines: [String] = []
            if let header = item.header.map(clean), !header.isEmpty { lines.append("**\(header)**") }
            lines.append(clean(item.prompt))
            for option in item.options {
                let detail = option.detail.map(clean).flatMap { $0.isEmpty ? nil : " — \($0)" } ?? ""
                lines.append("- \(clean(option.label))\(detail)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
        return Self.cut(text, 4096)
    }

    /// The headline: the first question.
    public func title(clean: (String) -> String) -> String {
        Self.cut(clean(question.items.first?.prompt ?? ""), 200)
    }

    /// The person's feed answer (question id -> selected option ids and Other text) as the
    /// question's own answer; nil when it names a question or option this one does not have.
    public func answer(_ answers: [String: (selected: [String], other: String?)]) -> AgentQuestionAnswer? {
        var selections: [String: AgentQuestionAnswer.Selection] = [:]
        for (key, selection) in answers {
            guard key.hasPrefix("q"), let index = Int(key.dropFirst()), question.items.indices.contains(index) else { return nil }
            let item = question.items[index]
            var ids: [String] = []
            for picked in selection.selected {
                guard picked.hasPrefix("o"), let optionIndex = Int(picked.dropFirst()),
                      item.options.indices.contains(optionIndex) else { return nil }
                ids.append(item.options[optionIndex].id)
            }
            let other = selection.other?.trimmingCharacters(in: .whitespacesAndNewlines)
            selections[item.id] = .init(optionIDs: ids, other: other?.isEmpty == false ? other : nil)
        }
        return AgentQuestionAnswer(selections: selections)
    }

    /// The `_acpmux/permission_respond` params that submit `answers`, nil when they do not fit.
    public func respondParams(_ answers: [String: (selected: [String], other: String?)]) -> [String: Any]? {
        guard let answer = answer(answers), let reply = try? question.reply(answer),
              let data = try? reply.params.data() else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The choice's title, body and prompt, or nil when a question or label is empty once
    /// `clean` made it fit to show (the owner would refuse it, and nothing would be posted at all).
    public func parts(clean: (String) -> String) -> (title: String, body: String, prompt: [String: Any])? {
        fits(clean: clean) ? (title(clean: clean), body(clean: clean), prompt(clean: clean)) : nil
    }

    func fits(clean: (String) -> String) -> Bool {
        question.items.allSatisfy { item in
            !clean(item.prompt).isEmpty && item.options.allSatisfy { !clean($0.label).isEmpty }
        }
    }

    /// `text` within `limit` UTF-16 units (the owner counts JavaScript string length), cut on a
    /// character boundary with an ellipsis.
    static func cut(_ text: String, _ limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var out = ""
        var units = 0
        for character in text {
            let width = character.utf16.count
            if units + width > limit - 1 { break }
            out.append(character)
            units += width
        }
        return out + "…"
    }
}
