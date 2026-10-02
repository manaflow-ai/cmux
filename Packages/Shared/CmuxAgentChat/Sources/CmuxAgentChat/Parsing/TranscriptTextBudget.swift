import Foundation

/// Defensive size limits applied to transcript-derived text.
///
/// Transcript lines can carry multi-megabyte payloads (whole-file writes,
/// base64 images); every body, diff, and detail string stored on a
/// ``ChatMessage`` is clamped here, in one place.
struct TranscriptTextBudget: Sendable {
    /// Limit for message bodies, tool outputs, and diffs (~16KB).
    let maxBodyCharacters: Int

    /// Limit for tool-input detail (~2KB).
    let maxInputDetailCharacters: Int

    /// Limit for the argument excerpt inside a one-line tool summary.
    let maxSummaryArgumentCharacters: Int

    /// Creates a budget.
    ///
    /// - Parameters:
    ///   - maxBodyCharacters: Limit for bodies, outputs, and diffs.
    ///   - maxInputDetailCharacters: Limit for tool-input detail.
    ///   - maxSummaryArgumentCharacters: Limit for summary arguments.
    init(
        maxBodyCharacters: Int = 16_384,
        maxInputDetailCharacters: Int = 2_048,
        maxSummaryArgumentCharacters: Int = 80
    ) {
        self.maxBodyCharacters = maxBodyCharacters
        self.maxInputDetailCharacters = maxInputDetailCharacters
        self.maxSummaryArgumentCharacters = maxSummaryArgumentCharacters
    }

    /// Clamps body-sized text (prose, thoughts, outputs, diffs).
    ///
    /// - Parameter text: The text to clamp.
    /// - Returns: The text, truncated with an ellipsis marker when over.
    func body(_ text: String) -> String {
        truncated(text, limit: maxBodyCharacters)
    }

    /// Clamps tool-input detail text.
    ///
    /// - Parameter text: The text to clamp.
    /// - Returns: The text, truncated with an ellipsis marker when over.
    func inputDetail(_ text: String) -> String {
        truncated(text, limit: maxInputDetailCharacters)
    }

    /// Clamps and single-lines an argument excerpt for a tool summary.
    ///
    /// - Parameter text: The argument text to excerpt.
    /// - Returns: A one-line excerpt within the summary limit.
    func summaryArgument(_ text: String) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return truncated(oneLine, limit: maxSummaryArgumentCharacters)
    }

    /// Truncates text to a character limit, marking the cut.
    ///
    /// - Parameters:
    ///   - text: The text to truncate.
    ///   - limit: The maximum character count.
    /// - Returns: The original text, or a truncated copy ending in `…`.
    private func truncated(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
