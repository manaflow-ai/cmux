import CmuxAgentQuestion
import Foundation

/// A terminal agent's question: Claude Code's AskUserQuestion (or a Codex
/// `request_user_input`) asked by an agent running in a Mac terminal tab, not
/// an acpmux chat. The daemon carries the tool's input on the question's
/// notification (`question`, memory only: cmux-tui `agent_hook_question.rs`),
/// so the Feed and the push show it like an acpmux question.
extension AgentQuestion {
    /// The question from the daemon's `question` (`{harness, tool_use_id?,
    /// questions}`), read by the parser acpmux questions use. `ledgerID` (the
    /// notification's row) is its id; its session is the terminal tab.
    public init?(terminalQuestion json: [String: Any], ledgerID: String, surface: Int) {
        guard let questions = json["questions"] as? [Any], !questions.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: questions),
              let input = try? AgentQuestionJSON(data: data) else { return nil }
        let meta: AgentQuestionJSON = (json["harness"] as? String) == "codex"
            ? ["codex": [:]]
            : ["claude": ["tool": "AskUserQuestion"]]
        let request: AgentQuestionJSON = ["toolCall": ["_meta": meta, "rawInput": ["questions": input]]]
        self.init(permissionRequest: request, permissionId: ledgerID, session: "s\(surface)")
    }
}

/// The keys that answer a terminal agent's question on its own screen,
/// as a person would type them. Only Claude Code's AskUserQuestion screen is
/// mapped; it was read live from Claude Code 2.1.308 (verify/push-matrix.md,
/// "Terminal agent questions"):
///
/// - each question is a tab; a single choice's number selects it and moves on;
/// - a multi-select's number checks or unchecks a row; Tab moves on;
/// - "Type something" is the row after the options: its number, then the
///   text (a single choice), Return; in a multi-select its number checks it, the
///   cursor goes down to it for the text, then down to Submit and Return;
/// - with more than one question, or any multi-select, a review screen ends
///   it, where 1 submits; one single-choice question has none;
/// - Escape cancels the question (Decline).
public struct TerminalQuestionKeys: Sendable {
    public struct Refusal: Error, Equatable, Sendable {
        public var message: String
    }

    static let down = "\u{1b}[B"
    static let escape = "\u{1b}"

    /// The keys for `answer`, one step each (the screen redraws between them).
    public static func keys(_ question: AgentQuestion, _ answer: AgentQuestionAnswer) throws -> [Data] {
        switch question.source.harness {
        case .claude: return try claude(question, answer)
        default: throw Refusal(message: String(localized: "Answer this one in the terminal."))
        }
    }

    static func claude(_ question: AgentQuestion, _ answer: AgentQuestionAnswer) throws -> [Data] {
        guard question.items.allSatisfy({ $0.options.count < 9 }) else {
            throw Refusal(message: String(localized: "Answer this one in the terminal."))
        }
        var steps: [String] = []
        for item in question.items {
            let selection = answer.selections[item.id] ?? .init()
            let numbers = selection.optionIDs.compactMap { id in item.options.firstIndex { $0.id == id }.map { $0 + 1 } }
            guard numbers.count == selection.optionIDs.count else {
                throw Refusal(message: String(localized: "That choice is no longer offered."))
            }
            let other = try selection.other.map(Self.typed)
            if other != nil && !item.allowsOther { throw Refusal(message: String(localized: "That choice is no longer offered.")) }
            let otherRow = item.options.count + 1
            if item.multiSelect {
                guard !numbers.isEmpty || other != nil else { throw Refusal(message: String(localized: "Answer every question first.")) }
                steps += numbers.sorted().map(String.init)
                if let other {
                    steps.append(String(otherRow))
                    steps.append(String(repeating: down, count: otherRow - 1))
                    steps.append(other)
                    steps.append(down)
                    steps.append("\r")
                } else {
                    steps.append("\t")
                }
            } else {
                switch (numbers.first, other) {
                case (let number?, nil) where numbers.count == 1: steps.append(String(number))
                case (nil, let other?): steps += [String(otherRow), other, "\r"]
                default: throw Refusal(message: String(localized: "Answer every question first."))
                }
            }
        }
        if question.items.count > 1 || question.items.contains(where: \.multiSelect) { steps.append("1") }
        return steps.map { Data($0.utf8) }
    }

    /// Escape: Claude Code cancels the question.
    public static var decline: [Data] { [Data(escape.utf8)] }

    /// Free text typed into "Type something": printable characters only, so the
    /// text can never press a key the person did not choose (Return, arrows, Escape).
    static func typed(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw Refusal(message: String(localized: "That answer can't be typed into the terminal."))
        }
        return trimmed
    }

    /// Whether `screen` (the terminal's text now) shows this question waiting:
    /// the first question's text, and each of its options at its own number.
    /// Keys go out only then, so they never land in another prompt or a shell.
    public static func screenShows(_ screen: String, question: AgentQuestion, answer: AgentQuestionAnswer) -> Bool {
        guard let item = question.items.first else { return false }
        let compact = { (text: String) in text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let shown = compact(screen)
        guard shown.contains(compact(String(item.prompt.prefix(80)))) else { return false }
        for (index, option) in item.options.enumerated() where !shown.contains("\(index + 1). \(compact(option.label))") {
            return false
        }
        return true
    }
}
