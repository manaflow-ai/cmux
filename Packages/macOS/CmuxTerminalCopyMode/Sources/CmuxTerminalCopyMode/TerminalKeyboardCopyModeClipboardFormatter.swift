/// Formats raw visual-line copy-mode text for clipboard fallback writes.
///
/// Ghostty's normal clipboard path owns rich formatting, codepoint mapping, and
/// trimming. cmux only uses this formatter when visual-line copy spans scrollback
/// outside the visible viewport and must fall back to an arbitrary text read.
public struct TerminalKeyboardCopyModeClipboardFormatter: Sendable {
    /// Creates a visual-line clipboard fallback formatter.
    public init() {}

    /// Removes full-row terminal padding from raw visual-line copy-mode text.
    ///
    /// - Parameter text: The raw text read from the terminal selection.
    /// - Returns: The text with trailing space and tab padding removed from each line.
    public func trimTrailingLinePadding(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for index in lines.indices {
            while lines[index].last.map({ $0 == " " || $0 == "\t" }) == true {
                lines[index].removeLast()
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Extracts visual-line fallback text from a full screen snapshot.
    ///
    /// - Parameters:
    ///   - text: The raw full-screen text returned by Ghostty's `screen` read.
    ///   - rows: The absolute screen-row range to copy, relative to the same snapshot.
    /// - Returns: The selected rows with trailing terminal-cell padding removed, or `nil` if the range is outside the snapshot.
    public func visualLineFallbackText(
        fromScreenText text: String,
        rows: ClosedRange<UInt64>
    ) -> String? {
        guard let lowerRow = Int(exactly: rows.lowerBound),
              let upperRow = Int(exactly: rows.upperBound) else { return nil }
        let screenRows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lowerRow >= 0,
              lowerRow < screenRows.count,
              upperRow < screenRows.count,
              upperRow >= lowerRow else { return nil }

        let selectedRows = screenRows[lowerRow ... upperRow].joined(separator: "\n")
        return trimTrailingLinePadding(selectedRows)
    }
}
