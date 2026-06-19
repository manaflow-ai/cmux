/// Bounds a string to a maximum number of lines and characters for compact
/// sidebar display, appending an ellipsis when truncation occurs.
extension String {
    /// Returns at most `maxDisplayedLines` lines and `maxDisplayedCharacters`
    /// characters of `self`. When the limit is hit, the result is trimmed of
    /// surrounding whitespace and newlines and suffixed with `"..."` (or the
    /// bare `"..."` when nothing printable remains). Returns `self` unchanged
    /// when it already fits within both limits.
    public func sidebarBoundedDisplayString(maxDisplayedLines: Int, maxDisplayedCharacters: Int) -> String {
        var result = ""
        result.reserveCapacity(maxDisplayedCharacters)
        var lineCount = 1
        var characterCount = 0
        var truncated = false

        for character in self {
            if characterCount >= maxDisplayedCharacters {
                truncated = true
                break
            }
            if character == "\n" {
                if lineCount >= maxDisplayedLines {
                    truncated = true
                    break
                }
                lineCount += 1
            }
            result.append(character)
            characterCount += 1
        }

        guard truncated else { return self }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "..." : trimmed + "..."
    }
}
