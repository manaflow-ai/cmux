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
public struct TerminalSoftWrapCopy: Equatable, Sendable {
    /// When true, also join a non-wrapped row that fills `terminalColumns`
    /// onto the following row.
    public var hardWrapReflow: Bool

    /// Grid width used by the hard-wrap heuristic.
    public var terminalColumns: Int

    /// Creates a copy builder.
    ///
    /// - Parameters:
    ///   - hardWrapReflow: Whether full-width rows reflow onto the next row.
    ///   - terminalColumns: Grid width used by the hard-wrap heuristic.
    public init(hardWrapReflow: Bool = false, terminalColumns: Int = 0) {
        self.hardWrapReflow = hardWrapReflow
        self.terminalColumns = terminalColumns
    }

    /// Joins soft-wrapped rows into logical lines.
    ///
    /// Wrapped rows are concatenated with no added separator. Rows Ghostty did
    /// not mark as wrapped stay separated by `\n`. Trailing ASCII spaces are
    /// removed from each logical line, matching clipboard trim.
    ///
    /// - Parameter rows: Physical rows in top-to-bottom order.
    /// - Returns: The copied text.
    public func joinedText(_ rows: [TerminalCopyRow]) -> String {
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
    /// - Returns: Copied text after soft-wrap joining and any enabled reflow.
    public func joiningSoftWraps(in text: String, wrapFlags: [Bool]?) -> String {
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
            return joinedText(rows)
        }
        guard hardWrapReflow, terminalColumns > 0 else { return text }
        let rows = lines.map { TerminalCopyRow(text: $0, wrapped: false) }
        return joinedText(rows)
    }

    private func shouldSoftJoin(
        _ previous: TerminalCopyRow,
        to row: TerminalCopyRow
    ) -> Bool {
        previous.wrapped && !previous.text.isEmpty && !row.text.isEmpty
    }

    private func shouldHardJoin(
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
        // Ghostty's copy already unwraps soft wraps, so a line wider than the
        // grid is a whole logical line, not a hard-wrapped row.
        return cellWidth(measured) == columns
    }

    private func hardJoined(_ current: String, _ next: String) -> String {
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

    private func startsStructuralLine(_ trimmed: Substring) -> Bool {
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

    private func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last == "." || last == "!" || last == "?"
    }

    /// Coarse terminal-cell width. East Asian Wide/Fullwidth blocks and
    /// common emoji count as two cells; combining marks, zero-width
    /// characters, and variation selectors count as zero.
    private func cellWidth(_ text: String) -> Int {
        var width = 0
        for scalar in text.unicodeScalars {
            let value = scalar.value
            switch value {
            case 0x0300...0x036F, 0x200B...0x200F, 0x20D0...0x20FF, 0xFE00...0xFE0F:
                continue
            case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
                 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F,
                 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F,
                 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
                width += 2
            default:
                width += 1
            }
        }
        return width
    }

    private func trimmingTrailingSpaces(_ text: String) -> String {
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
    public func physicalLineCount(in text: String) -> Int {
        splitCopiedLines(text).count
    }

    private func splitCopiedLines(_ text: String) -> [String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        return lines
    }
}
