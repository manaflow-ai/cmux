import CmuxHomeCore
import Foundation

/// What a Chief conversation's list row says on its second line: the newest
/// human-readable line, never a log fragment (design references, `topics/sidebar.md`:
/// the preview is the last human-readable line).
///
/// The rules, in order, over the conversation's newest messages:
/// 1. An approval card that waits (newer than my last message): "Needs your
///    approval: Start Codex in “Scratch”", the card's action in plain words.
/// 2. A question card that waits: "Needs your answer: <the question>", never its options.
/// 3. A tool call that runs: its row's line ("Running cmux tree --all", "Starting Codex in …").
/// 4. Otherwise the newest bubble: a text, attachment, link or location message (the host
///    formats it, Markdown flattened), or a Cloud result card's title (not its meta line).
///
/// Never a system row (a saved note, "Stopped", a failed turn's row), a finished tool row, a
/// decided approval or an answered question. Pure: tests pin each kind.
public struct ChiefListPreview: Hashable, Sendable {
    public enum Line: Hashable, Sendable {
        /// An approval waits; the text is the full line.
        case needsApproval(String)
        /// A question waits; the text is the full line.
        case needsAnswer(String)
        /// A tool call runs; the text is its row's line.
        case running(String)
        /// A Cloud result card's title.
        case card(String)
        /// The newest bubble, for the host to format.
        case message(CmuxHomeCore.Message)

        /// The line as shown, nil for `.message` (the host formats the message).
        public var text: String? {
            switch self {
            case .needsApproval(let s), .needsAnswer(let s), .running(let s), .card(let s): s
            case .message: nil
            }
        }
    }

    /// The preview, nil when no message qualifies (an empty conversation, or one with only
    /// system rows): the host keeps its own fallback.
    public let line: Line?

    /// - Parameters:
    ///   - messages: The conversation's newest messages, ascending.
    ///   - me: The user: a waiting card counts only when it is newer than my last message.
    public init(messages: [CmuxHomeCore.Message], me: ParticipantID) {
        line = Self.line(in: messages, me: me)
    }

    static func line(in messages: [CmuxHomeCore.Message], me: ParticipantID) -> Line? {
        let live = messages.filter { !$0.isRetracted && !$0.parts.isEmpty }
        // The turn after my newest message: what waits or runs belongs to it.
        let turn = live.lastIndex(where: { $0.author == me }).map { live[(live.index(after: $0))...] } ?? live[...]
        for message in turn.reversed() {
            for case .approval(let ref) in message.parts where ref.decided == nil {
                return .needsApproval(CmuxStrings.previewNeedsApproval(approvalSubject(ref.prompt)))
            }
        }
        for message in turn.reversed() {
            for case .question(let question) in message.parts where question.isPending && !question.summary.isEmpty {
                return .needsAnswer(CmuxStrings.previewNeedsAnswer(question.summary))
            }
        }
        for message in turn.reversed() {
            for case .work(let work) in message.parts where work.status == .running || work.status == .waiting {
                if let line = runningLine(work) { return .running(line) }
            }
        }
        for message in live.reversed() {
            if message.parts.contains(where: isBubble) { return .message(message) }
            for case .work(let work) in message.parts where ChiefCloudRows.isResult(work) && !work.title.isEmpty {
                return .card(work.title)
            }
        }
        return nil
    }

    /// A part drawn as a bubble (words or media), not a row or card.
    static func isBubble(_ part: MessagePart) -> Bool {
        switch part {
        case .text(let text, _): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .attachment, .linkPreview, .location: true
        case .work, .approval, .question: false
        }
    }

    /// What an approval asks, in plain words: `cmux chief dispatch` as "Start Codex in “Scratch”",
    /// another command as itself, "Allow <tool>?" as the tool's title, any other prompt as written.
    static func approvalSubject(_ prompt: String) -> String {
        if let command = ChiefRows.command(inPrompt: prompt) {
            return dispatchStart(command) ?? command
        }
        if prompt.hasPrefix("Allow "), prompt.hasSuffix("?"), prompt.count > "Allow ?".count {
            return ChiefRows.displayTitle(String(prompt.dropFirst("Allow ".count).dropLast()))
        }
        return prompt
    }

    /// "Start Codex in “Scratch”" for a `cmux chief dispatch` command.
    static func dispatchStart(_ command: String) -> String? {
        guard let all = ChiefRows.words(command), Array(all.prefix(3)) == ["cmux", "chief", "dispatch"] else { return nil }
        let flags = Array(all.dropFirst(3).prefix { $0 != "--" })
        func value(_ name: String) -> String? {
            for (i, w) in flags.enumerated() {
                if w.hasPrefix(name + "=") { return String(w.dropFirst(name.count + 1)) }
                if w == name, i + 1 < flags.count { return flags[i + 1] }
            }
            return nil
        }
        guard let agent = value("--agent").map(ChiefRows.agentName) else { return nil }
        let subject = value("--name").flatMap { $0.isEmpty ? nil : CmuxStrings.dispatchSubject(agent: agent, workspace: $0) } ?? agent
        return CmuxStrings.dispatchStart(subject)
    }

    /// A running work part's line: a tool call's row text, a Cloud provisioning row's
    /// "Creating cloud machine…"; nil for a system row or a hidden call (a memory save).
    static func runningLine(_ work: WorkRef) -> String? {
        if ChiefCloudRows.isProvisioning(work) { return CmuxStrings.cloudCreating("").trimmingCharacters(in: .whitespaces) }
        guard work.host == nil, !ChiefRows.isNotice(work), !ChiefRows.savesMemory(work) else { return nil }
        return ChiefRows.lineText(ChiefRows.ToolCall(work))
    }
}
