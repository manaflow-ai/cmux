/// Joins pasted text into a single line for "Paste as One Line".
///
/// A long command copied from a chat window or an agent's terminal output
/// often reaches the clipboard with a line break at every visual wrap point.
/// Pasted as is, a shell runs each fragment as its own command. Joining puts
/// the command back on one line so the shell sees it whole, and nothing runs
/// until the user presses Return.
///
/// The join is deliberately plain, because the user asks for it explicitly:
///
/// - A line ending in an unescaped backslash continuation loses that
///   backslash.
/// - Each line is trimmed of leading and trailing spaces and tabs.
/// - Blank lines are dropped.
/// - The remaining lines are joined with one space.
///
/// Text that is several commands on purpose, such as a heredoc, is not
/// something to join; that is the ordinary Paste.
public enum TerminalPasteLineJoin {
    /// Whether `text` holds a line break other than trailing ones, the case
    /// where "Paste as One Line" differs from Paste.
    ///
    /// - Parameter text: The clipboard text.
    /// - Returns: `true` when joining would change which lines the shell
    ///   receives.
    public static func spansMultipleLines(_ text: String) -> Bool {
        lines(of: text).count > 1
    }

    /// Returns `text` joined into one line.
    ///
    /// - Parameter text: The clipboard text.
    /// - Returns: The joined text, with no line breaks. Empty when `text`
    ///   holds only whitespace.
    public static func joined(_ text: String) -> String {
        lines(of: text).joined(separator: " ")
    }

    /// The non-blank lines of `text`, trimmed, with continuation backslashes
    /// removed.
    private static func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            var line = trimmingHorizontalWhitespace(rawLine)
            if endsWithContinuation(line) {
                line.removeLast()
                line = trimmingHorizontalWhitespace(line)
            }
            return line.isEmpty ? nil : String(line)
        }
    }

    /// Whether `line` ends in an odd run of backslashes, so the last one
    /// escapes the line break rather than another backslash.
    private static func endsWithContinuation(_ line: Substring) -> Bool {
        let trailingBackslashes = line.reversed().prefix(while: { $0 == "\\" }).count
        return trailingBackslashes % 2 == 1
    }

    private static func trimmingHorizontalWhitespace(_ line: Substring) -> Substring {
        let isHorizontalWhitespace: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        guard let start = line.firstIndex(where: { !isHorizontalWhitespace($0) }),
              let end = line.lastIndex(where: { !isHorizontalWhitespace($0) }) else {
            return line[line.endIndex...]
        }
        return line[start...end]
    }
}
