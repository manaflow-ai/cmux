/// A plain-text capture of a terminal surface for the mobile "View as Text"
/// sheet, capped to a line budget so a giant scrollback cannot bog down the
/// sheet's text view.
///
/// The cap keeps the LAST `lineBudget` lines: the user opening the sheet is
/// after the output that just happened, not the oldest history. `isTruncated`
/// drives the sheet's "showing the last N lines" banner.
public struct TerminalTextSnapshot: Equatable, Sendable {
    /// The text the sheet shows, already capped to `lineBudget` lines.
    public let text: String

    /// Whether older lines were dropped to fit `lineBudget`.
    public let isTruncated: Bool

    /// The line budget `text` was capped to.
    public let lineBudget: Int

    /// Default budget: generous enough to carry the recent scrollback the user
    /// wants to copy from, small enough that the sheet's `UITextView` lays out
    /// without jank.
    public static let defaultLineBudget = 5000

    /// Creates a snapshot from already-capped text.
    ///
    /// Prefer ``capped(fullText:lineBudget:)``, which derives all three fields
    /// from raw terminal text; this memberwise initializer exists for tests
    /// and callers that have applied their own bound.
    ///
    /// - Parameters:
    ///   - text: The capped text the sheet shows.
    ///   - isTruncated: Whether older lines were dropped to fit `lineBudget`.
    ///   - lineBudget: The line budget `text` was capped to.
    public init(text: String, isTruncated: Bool, lineBudget: Int) {
        self.text = text
        self.isTruncated = isTruncated
        self.lineBudget = lineBudget
    }

    /// Cap `fullText` to the last `lineBudget` lines.
    ///
    /// Trailing whitespace-only lines are trimmed first: the libghostty
    /// "screen" read includes written-but-blank rows below the last real
    /// output, which would otherwise pad the sheet (and eat budget) with empty
    /// tail lines.
    ///
    /// - Parameters:
    ///   - fullText: The terminal's text, newline-separated.
    ///   - lineBudget: Maximum number of lines to keep. Must be positive.
    /// - Returns: The capped snapshot.
    public static func capped(
        fullText: String,
        lineBudget: Int = defaultLineBudget
    ) -> TerminalTextSnapshot {
        precondition(lineBudget > 0, "lineBudget must be positive")
        var lines = fullText.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let last = lines.last, last.allSatisfy(\.isWhitespace) {
            lines = lines.dropLast()
        }
        let isTruncated = lines.count > lineBudget
        if isTruncated {
            lines = lines.suffix(lineBudget)
        }
        return TerminalTextSnapshot(
            text: lines.joined(separator: "\n"),
            isTruncated: isTruncated,
            lineBudget: lineBudget
        )
    }
}
