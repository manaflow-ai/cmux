/// Unwraps selected terminal output while preserving lists, tables, and fenced code.
///
/// Apply ``TerminalSoftWrapCopy`` first for a nonrectangular selection.
public struct TerminalUnwrappedCopy: Equatable, Sendable {
    /// The shared clipboard byte budget, above which text is copied unchanged.
    public static let maximumUnwrapBytes = TerminalClipboardRepresentationDecoder.defaultMaximumRichTextBytes

    /// The terminal grid width used to recognize hard-wrapped output.
    public var terminalColumns: Int

    /// Whether the selection is rectangular and must retain row boundaries.
    public var rectangular: Bool

    /// The selected first row's viewport column, or nil when unavailable.
    public var firstLineStartColumn: Int?

    /// Creates an unwrapper for a terminal selection.
    ///
    /// - Parameters:
    ///   - terminalColumns: Grid width. Zero disables hard-wrap reflow.
    ///   - rectangular: Whether to preserve all row boundaries.
    ///   - firstLineStartColumn: Selection start column; nil preserves the indentation heuristic.
    public init(terminalColumns: Int, rectangular: Bool = false, firstLineStartColumn: Int? = nil) {
        self.terminalColumns = terminalColumns
        self.rectangular = rectangular
        self.firstLineStartColumn = firstLineStartColumn
    }

    /// Trims, dedents, and reflows selected plain text.
    ///
    /// - Parameter text: Selection text with soft wraps already joined.
    /// - Returns: Unwrapped plain text, or the unchanged input above ``maximumUnwrapBytes``.
    public func unwrappedText(_ text: String) -> String {
        guard text.utf8.count <= Self.maximumUnwrapBytes else { return text }
        var fence: Substring = ""
        var protected: [Bool] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            var line = String(raw.reversed().drop(while: \.isWhitespace).reversed())
            var content = line.drop(while: \.isWhitespace)
            let inside = !fence.isEmpty
            // Strip the marker before looking for a fence, so "⏺ ```sh" still opens one.
            if !inside, let first = content.first, "⏺●⎿✻✳✶✢✽".contains(first),
               content.dropFirst().first == " " {
                let index = line.index(line.startIndex, offsetBy: line.count - content.count)
                line.replaceSubrange(index...index, with: " ")
                content = line.drop(while: \.isWhitespace)
            }
            let delimiter = fenceDelimiter(content)
            protected.append(inside || !delimiter.isEmpty)
            if inside {
                if delimiter.first == fence.first, delimiter.count >= fence.count,
                   content.dropFirst(delimiter.count).allSatisfy(\.isWhitespace) {
                    fence = ""
                }
            } else if !delimiter.isEmpty {
                fence = delimiter
            }
            return line
        }
        var widths = lines.map(width)
        if !widths.isEmpty { widths[0] += firstLineStartColumn ?? 0 }
        let widest = lines.indices.filter { !protected[$0] && widths[$0] <= terminalColumns }
            .map { widths[$0] }.max() ?? 0
        let nonblank = lines.indices.filter { !lines[$0].isEmpty }
        let restIndent = nonblank.dropFirst().map { indent(lines[$0]) }.min()
        let partialFirst = nonblank.first.map {
            firstLineStartColumn.map { $0 > 0 } ?? (indent(lines[$0]) < (restIndent ?? 0)
                && !startsStructure(lines[$0].drop(while: \.isWhitespace)))
        } ?? false
        let common = (partialFirst ? Array(nonblank.dropFirst()) : nonblank)
            .map { indent(lines[$0]) }.min() ?? 0
        let dedented = lines.indices.map { index in
            String(lines[index].dropFirst(partialFirst && index == nonblank.first ? indent(lines[index]) : common))
        }
        let canReflow = !rectangular && terminalColumns > 0 && widest >= terminalColumns - 12
        var result: [String] = []
        var continuationIndent = 0
        for index in lines.indices {
            let line = dedented[index]
            if line.isEmpty && !protected[index] {
                if !result.isEmpty && result.last != "" { result.append("") }
                continue
            }
            let content = line.drop(while: \.isWhitespace)
            let nextWordWidth = width(String(content.prefix(while: { !$0.isWhitespace })))
            let separator = index > 0 ? rowJoinSeparator(
                after: dedented[index - 1], before: content, fillsWidth: widths[index - 1] == widest,
                nextWordFitsGrid: widths[index - 1] + 1 + nextWordWidth <= terminalColumns
            ) : nil
            let joins = canReflow && index > 0 && !protected[index] && !protected[index - 1]
                && !line.isEmpty && !dedented[index - 1].isEmpty && separator != nil
                && widths[index - 1] <= terminalColumns
                && !endsWithContinuation(dedented[index - 1])
                && !startsStructure(content) && !endsBlock(dedented[index - 1])
                && indent(line) == continuationIndent
                && !isColumnar(line) && !isColumnar(dedented[index - 1])
                && ((firstLineStartColumn == nil && partialFirst && index - 1 == nonblank.first)
                    || widths[index - 1] + 1 + nextWordWidth > widest)
            if joins, var previous = result.popLast() {
                previous.append(contentsOf: separator ?? " ")
                previous.append(contentsOf: content)
                result.append(previous)
            } else {
                result.append(line)
                continuationIndent = indent(line) + listPrefixLength(content)
            }
        }
        if result.last == "", protected.last != true { result.removeLast() }
        return result.joined(separator: "\n")
    }

    private func width(_ text: String) -> Int {
        TerminalSoftWrapCopy().cellWidth(text)
    }

    private func indent(_ text: String) -> Int {
        text.prefix(while: \.isWhitespace).count
    }

    private func fenceDelimiter(_ content: Substring) -> Substring {
        guard let first = content.first, first == "`" || first == "~" else { return "" }
        let run = content.prefix(while: { $0 == first })
        return run.count >= 3 ? run : ""
    }

    private func startsStructure(_ content: Substring) -> Bool {
        if listPrefixLength(content) > 0 || !fenceDelimiter(content).isEmpty { return true }
        if let first = content.first, "#>|".contains(first) { return true }
        if content.hasPrefix("$ ") { return true }
        if content.first == "-", let next = content.dropFirst().first, !next.isWhitespace { return true }
        let compact = content.filter { !$0.isWhitespace }
        return compact.count >= 3 && "-*_".contains(compact.first ?? " ")
            && compact.allSatisfy { $0 == compact.first }
    }

    private func isColumnar(_ line: String) -> Bool {
        line.drop(while: \.isWhitespace).contains("   ")
            || line.unicodeScalars.contains { (0x2500...0x257F).contains($0.value) }
    }

    private func endsWithContinuation(_ line: String) -> Bool {
        line.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1
    }
}
