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
public struct TerminalPasteLineJoin: Equatable, Sendable {
    /// The non-blank lines of the pasted text, trimmed, with continuation
    /// backslashes removed.
    public let lines: [String]

    /// Splits `text` into the lines a one-line paste joins.
    ///
    /// - Parameter text: The clipboard text.
    public init(_ text: String) {
        lines = text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            var line = Self.trimmingHorizontalWhitespace(rawLine)
            if Self.endsWithContinuation(line) {
                line.removeLast()
                line = Self.trimmingHorizontalWhitespace(line)
            }
            return line.isEmpty ? nil : String(line)
        }
    }

    /// Whether the text holds a line break other than trailing ones, the case
    /// where "Paste as One Line" differs from Paste.
    public var spansMultipleLines: Bool {
        lines.count > 1
    }

    /// The text joined into one line, with no line breaks. Empty when the
    /// text holds only whitespace.
    public var joined: String {
        lines.joined(separator: " ")
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
