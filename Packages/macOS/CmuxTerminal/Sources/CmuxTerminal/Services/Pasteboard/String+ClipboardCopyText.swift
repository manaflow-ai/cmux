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

    /// This terminal viewport text with the blank rows below the last line of
    /// output removed, or `nil` when the screen is blank.
    ///
    /// A viewport reads back as one line per row, so a mostly empty screen
    /// ends in a run of blank rows. Those are dropped, the same as
    /// `$(cmux read-screen)` in a shell drops trailing newlines. Leading rows
    /// and indentation are kept.
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
