internal import Foundation

/// Formats selected diff context and a user note for an agent.
struct DiffPromptFormatter: Sendable {
    /// Creates a prompt formatter.
    init() {}

    /// Produces the exact fenced diff prompt sent or placed in the composer.
    /// - Parameters:
    ///   - context: Selected file, line, hunk, and excerpt.
    ///   - note: User-authored instruction; surrounding whitespace is removed.
    /// - Returns: An unambiguous prompt with an ASCII `diff` fence.
    func prompt(context: DiffNoteContext, note: String) -> String {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = """
        Regarding `\(context.path)` line \(context.lineReference.promptText), hunk \(context.hunkReference):
        ```diff
        \(context.excerpt)
        ```
        """
        return trimmedNote.isEmpty ? prefix : "\(prefix)\n\(trimmedNote)"
    }
}
