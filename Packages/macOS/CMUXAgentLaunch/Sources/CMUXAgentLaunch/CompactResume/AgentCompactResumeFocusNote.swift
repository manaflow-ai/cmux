/// The focus instructions for a compaction, built from what the pane was
/// working on.
///
/// The note is one short line so it types into the agent's input as a normal
/// prompt rather than a collapsed paste. It names the task in flight, taken
/// from the session's last real prompt, and asks the summary to keep file
/// paths, decisions, and open TODOs:
///
/// ```swift
/// let note = AgentCompactResumeFocusNote(recentPrompts: ["fix the flaky sidebar test"])
/// note.text // "Keep the current task: fix the flaky sidebar test; keep file paths, decisions and open TODOs."
/// ```
public struct AgentCompactResumeFocusNote: Sendable, Equatable {
    /// How every resume prompt starts. Prompts that start with it are cmux's
    /// own and never become the task line of a later run.
    public static let resumePreamble = "Continue where you left off."
    /// The longest task taken from a prompt, in characters.
    public static let taskLimit = 160
    /// The longest focus note, in characters.
    public static let textLimit = 320

    /// The focus instructions for the compaction.
    public let text: String
    /// What the resume prompt adds after ``resumePreamble``: the user's own
    /// focus, or the task in flight. `nil` when neither is known.
    public let taskLine: String?

    /// Builds the note.
    ///
    /// - Parameters:
    ///   - recentPrompts: The session's latest user prompts, oldest first.
    ///     Slash commands and earlier resume prompts are skipped.
    ///   - customFocus: Focus text the caller supplied. When non-empty it
    ///     replaces the generated note.
    public init(recentPrompts: [String], customFocus: String? = nil) {
        if let custom = customFocus.map(Self.singleLine), !custom.isEmpty {
            let clipped = Self.clip(custom, to: Self.textLimit)
            text = clipped
            taskLine = clipped
            return
        }
        let task = recentPrompts.reversed().lazy
            .map(Self.singleLine)
            .first { !$0.isEmpty && !$0.hasPrefix("/") && !$0.hasPrefix(Self.resumePreamble) }
            .map { Self.clip($0, to: Self.taskLimit) }
        if let task {
            text = "Keep the current task: \(task); keep file paths, decisions and open TODOs."
            taskLine = "Current task: \(task)"
        } else {
            text = "Keep the task in progress, file paths, decisions and open TODOs."
            taskLine = nil
        }
    }

    /// Collapses every run of whitespace, newlines included, to one space.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    static func clip(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit - 1).trimmingTrailingWhitespace()
        return head + "…"
    }
}

private extension Substring {
    func trimmingTrailingWhitespace() -> String {
        var end = endIndex
        while end > startIndex, self[index(before: end)].isWhitespace {
            end = index(before: end)
        }
        return String(self[startIndex..<end])
    }
}
