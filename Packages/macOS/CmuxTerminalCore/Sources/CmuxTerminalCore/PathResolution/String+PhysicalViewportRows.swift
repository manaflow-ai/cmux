extension String {
    /// Splits `ghostty_surface_read_text_physical_rows` output into exactly
    /// `expectedRows` lines, one per physical viewport row, or `nil` if the
    /// text can't be reconciled with that row count safely.
    ///
    /// Mirrors the exact rules the API's soft-wrap-boundary contract implies
    /// for a caller that must map a screen row index back into this array:
    ///
    /// 1. Split with `omittingEmptySubsequences: false` so leading and inner
    ///    empty rows survive as empty strings, never silently collapsed.
    /// 2. If the split produces exactly `expectedRows + 1` entries and the
    ///    last is empty, that's a terminating-newline sentinel, not an
    ///    extra row — drop only that trailing entry.
    /// 3. If fewer than `expectedRows` entries remain, pad the *end* only
    ///    (never the front — that would shift every earlier row's index).
    /// 4. Any other entry count above `expectedRows` is a snapshot
    ///    inconsistency (not a normal short-selection case) and fails
    ///    closed — this never silently truncates with `prefix(rows)`, since
    ///    that would misattribute a later row's text to an earlier index.
    public func splitPhysicalViewportRows(expectedRows: Int) -> [String]? {
        guard expectedRows > 0 else { return nil }

        var lines = split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count == expectedRows + 1, lines.last == "" {
            lines.removeLast()
        }
        guard lines.count <= expectedRows else { return nil }
        if lines.count < expectedRows {
            lines.append(contentsOf: repeatElement("", count: expectedRows - lines.count))
        }
        return lines
    }
}
