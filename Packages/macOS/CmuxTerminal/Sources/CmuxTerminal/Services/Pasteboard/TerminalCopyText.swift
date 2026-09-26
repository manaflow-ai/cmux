public import Foundation

/// Decides what text a cmux copy action puts on the clipboard.
///
/// Copy actions (working directory, project root, visible screen) must never
/// replace the user's clipboard with nothing: an empty or whitespace-only
/// source yields `nil`, and callers treat that as "nothing to copy".
public enum TerminalCopyText {
    /// The text to copy verbatim, or `nil` when it is missing or contains only
    /// whitespace and newlines.
    ///
    /// - Parameter text: The candidate text, such as a directory path.
    /// - Returns: `text` unchanged, or `nil` when there is nothing to copy.
    public static func payload(_ text: String?) -> String? {
        guard let text, !isBlank(text) else { return nil }
        return text
    }

    /// The visible-screen text to copy, with the blank rows below the last
    /// line of output removed, or `nil` when the screen is blank.
    ///
    /// A terminal viewport reads back as one line per row, so a mostly empty
    /// screen ends in a run of blank rows. Those are dropped, the same as
    /// `$(cmux read-screen)` in a shell drops trailing newlines. Leading rows
    /// and indentation are kept.
    ///
    /// - Parameter text: The viewport text read from the terminal.
    /// - Returns: The trimmed screen text, or `nil` when there is nothing to copy.
    public static func visibleScreenPayload(_ text: String?) -> String? {
        guard let text else { return nil }
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous].isWhitespace else { break }
            end = previous
        }
        return payload(String(text[..<end]))
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy(\.isWhitespace)
    }
}
