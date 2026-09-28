/// How compact-and-resume talks to one agent's terminal UI.
///
/// Claude Code's `/compact` takes focus instructions; Codex's `/compact` takes
/// none, so for Codex the focus only reaches the agent through the resume
/// prompt.
public enum AgentCompactResumeDialect: String, Sendable, Equatable, CaseIterable {
    /// Claude Code.
    case claudeCode
    /// OpenAI Codex CLI.
    case codex

    /// The glyph that starts the agent's input line.
    public var promptGlyph: Character {
        switch self {
        case .claudeCode: "❯"
        case .codex: "›"
        }
    }

    /// Whether the input box closes with a horizontal rule. Claude Code draws
    /// one above and below its input, so a multi-line draft is every line up
    /// to that rule. Codex draws none; only its prompt line is read.
    public var inputBoxClosesWithRule: Bool { self == .claudeCode }

    /// The slash command that compacts the agent's context.
    ///
    /// - Parameter focus: What the summary should keep.
    /// - Returns: A single-line command to type and submit.
    public func compactCommand(focus: AgentCompactResumeFocusNote) -> String {
        switch self {
        case .claudeCode: "/compact \(focus.text)"
        case .codex: "/compact"
        }
    }

    /// The prompt sent once compaction has finished.
    ///
    /// - Parameter focus: The focus the compaction used.
    /// - Returns: A single-line prompt to type and submit.
    public func resumePrompt(focus: AgentCompactResumeFocusNote) -> String {
        guard let taskLine = focus.taskLine else { return AgentCompactResumeFocusNote.resumePreamble }
        return "\(AgentCompactResumeFocusNote.resumePreamble) \(taskLine)"
    }
}
