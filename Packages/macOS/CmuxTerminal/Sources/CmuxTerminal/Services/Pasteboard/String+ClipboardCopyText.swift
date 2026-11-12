public import Foundation

// cmux copy actions (working directory, project root, visible screen) must
// never replace the user's clipboard with nothing. These properties return
// `nil` for text that contains only whitespace and newlines, and callers treat
// `nil` as "nothing to copy".
extension String {
    /// This text unchanged, or `nil` when it is empty or contains only
    /// whitespace and newlines.
    public var nonBlankClipboardText: String? {
        allSatisfy(\.isWhitespace) ? nil : self
    }

    /// This terminal viewport text with all trailing whitespace removed, or
    /// `nil` when the screen is blank.
    ///
    /// A viewport reads back as one line per row, so a mostly empty screen
    /// ends in a run of blank rows. Every trailing space, tab, and newline is
    /// dropped, including trailing spaces on the last line of output (a shell
    /// `$(cmux read-screen)` would keep those). Leading rows and indentation
    /// are kept.
    public var visibleScreenClipboardText: String? {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            guard self[previous].isWhitespace else { break }
            end = previous
        }
        return String(self[..<end]).nonBlankClipboardText
    }
}
