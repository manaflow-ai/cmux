/// One physical terminal row and Ghostty's wrap flag for that row.
///
/// `wrapped` is the row wrap flag: the row continues onto the next physical
/// row. A soft-wrapped logical line is consecutive rows whose earlier rows
/// are marked wrapped.
public struct TerminalCopyRow: Equatable, Sendable {
    /// Cell text for this physical row, in display order.
    public var text: String

    /// Whether Ghostty marked this row as wrapping onto the next row.
    public var wrapped: Bool

    /// Creates a copy row.
    public init(text: String, wrapped: Bool) {
        self.text = text
        self.wrapped = wrapped
    }
}

/// Builds copied terminal text from physical rows.
///
/// Soft-wrap joining follows Ghostty's row wrap flag and is unconditional.
/// Hard-wrap reflow is a width heuristic and runs only when the caller turns
/// it on.
public enum TerminalSoftWrapCopy {
    /// Joins soft-wrapped rows into logical lines.
    ///
    /// Wrapped rows are concatenated with no added separator. Rows Ghostty did
    /// not mark as wrapped stay separated by `\n`. Trailing ASCII spaces are
    /// removed from each logical line, matching clipboard trim.
    ///
    /// - Parameters:
    ///   - rows: Physical rows in top-to-bottom order.
    ///   - hardWrapReflow: When true, also join a non-wrapped row that fills
    ///     `terminalColumns` onto the following row.
    ///   - terminalColumns: Grid width used by the hard-wrap heuristic.
    /// - Returns: The copied text.
    public static func joinedText(
        _ rows: [TerminalCopyRow],
        hardWrapReflow: Bool = false,
        terminalColumns: Int = 0
    ) -> String {
        guard let first = rows.first else { return "" }
        var lines: [String] = []
        var current = first.text
        if rows.count > 1 {
            for index in 1..<rows.count {
                let previous = rows[index - 1]
                let row = rows[index]
                if shouldSoftJoin(previous, to: row) {
                    current += row.text
                } else if hardWrapReflow,
                          shouldHardJoin(
                              previous.text,
                              next: row.text,
                              columns: terminalColumns
                          ) {
                    current = hardJoined(current, row.text)
                } else {
                    lines.append(trimmingTrailingSpaces(current))
                    current = row.text
                }
            }
        }
        lines.append(trimmingTrailingSpaces(current))
        return lines.joined(separator: "\n")
    }

    /// Applies wrap-flag joining to text Ghostty already emitted.
    ///
    /// `wrapFlags` lines up with physical rows. Ghostty's own clipboard
    /// formatter already removes soft-wrap breaks, so a flag list longer than
    /// the emitted line list is left unchanged. When the counts match, each
    /// emitted line is still one physical row and wrapped rows are joined.
    ///
    /// - Parameters:
    ///   - text: Plain text from the current copy path.
    ///   - wrapFlags: Ghostty wrap flag for each selected physical row, or
    ///     nil when the flags are unavailable.
    ///   - hardWrapReflow: When true, also reflow lines that fill the grid.
    ///   - terminalColumns: Grid width used by the hard-wrap heuristic.
    /// - Returns: Copied text after soft-wrap joining and any enabled reflow.
    public static func joiningSoftWraps(
        in text: String,
        wrapFlags: [Bool]?,
        hardWrapReflow: Bool = false,
        terminalColumns: Int = 0
    ) -> String {
        guard text.contains("\n") else { return text }
        let lines = splitCopiedLines(text)
        if let wrapFlags, wrapFlags.count == lines.count {
            // Flags that are all false mean Ghostty did not mark a soft wrap.
            // Leave the clipboard bytes alone unless hard-wrap reflow is on.
            if !hardWrapReflow, !wrapFlags.contains(true) {
                return text
            }
            let rows = zip(lines, wrapFlags).map { line, wrapped in
                TerminalCopyRow(text: line, wrapped: wrapped)
            }
            return joinedText(
                rows,
                hardWrapReflow: hardWrapReflow,
                terminalColumns: terminalColumns
            )
        }
        guard hardWrapReflow, terminalColumns > 0 else { return text }
        let rows = lines.map { TerminalCopyRow(text: $0, wrapped: false) }
        return joinedText(
            rows,
            hardWrapReflow: true,
            terminalColumns: terminalColumns
        )
    }

    private static func shouldSoftJoin(
        _ previous: TerminalCopyRow,
        to row: TerminalCopyRow
    ) -> Bool {
        previous.wrapped && !previous.text.isEmpty && !row.text.isEmpty
    }

    private static func shouldHardJoin(
        _ physicalRow: String,
        next: String,
        columns: Int
    ) -> Bool {
        guard columns > 0 else { return false }
        let nextContent = next.drop(while: { $0 == " " })
        guard !nextContent.isEmpty, !startsStructuralLine(nextContent) else {
            return false
        }
        let measured = trimmingTrailingSpaces(physicalRow)
        guard !measured.isEmpty, !endsSentence(measured) else { return false }
        return cellWidth(measured) >= columns
    }

    private static func hardJoined(_ current: String, _ next: String) -> String {
        var continuation = next
        if !current.hasSuffix(" "), continuation.hasPrefix(" ") {
            let indent = continuation.prefix(while: { $0 == " " })
            if indent.count > 0, indent.count <= 2 {
                continuation.removeFirst(indent.count)
            }
        }
        if current.hasSuffix(" ") || continuation.hasPrefix(" ") || continuation.isEmpty {
            return current + continuation
        }
        return current + " " + continuation
    }

    private static func startsStructuralLine(_ trimmed: Substring) -> Bool {
        if trimmed.hasPrefix("```")
            || trimmed.hasPrefix("#")
            || trimmed.hasPrefix("|")
            || trimmed.hasPrefix(">")
            || trimmed.hasPrefix("- ")
            || trimmed.hasPrefix("* ")
            || trimmed.hasPrefix("+ ") {
            return true
        }
        guard let first = trimmed.first, first.isNumber else { return false }
        let rest = trimmed.drop(while: \.isNumber)
        return rest.hasPrefix(". ")
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last == "." || last == "!" || last == "?"
    }

    /// Coarse terminal-cell width. Scalars in the East Asian range count as
    /// two cells; combining marks in the common block count as zero.
    private static func cellWidth(_ text: String) -> Int {
        var width = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value >= 0x0300 && value <= 0x036F { continue }
            width += value >= 0x1100 ? 2 : 1
        }
        return width
    }

    private static func trimmingTrailingSpaces(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            if text[previous] != " " { break }
            end = previous
        }
        return String(text[..<end])
    }

    /// Physical lines in copied text, dropping one trailing empty line from a
    /// final newline so the count matches Ghostty's row span.
    public static func physicalLineCount(in text: String) -> Int {
        splitCopiedLines(text).count
    }

    private static func splitCopiedLines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }
}
