/// Unwraps selected terminal output while preserving lists, tables, and fenced code.
///
/// Apply ``TerminalSoftWrapCopy`` first for a nonrectangular selection.
public struct TerminalUnwrappedCopy: Equatable, Sendable {
    /// The terminal grid width used to recognize hard-wrapped output.
    public var terminalColumns: Int

    /// Whether the selection is rectangular and must retain row boundaries.
    public var rectangular: Bool

    /// Creates an unwrapper for a terminal selection.
    ///
    /// - Parameters:
    ///   - terminalColumns: Grid width. Zero disables hard-wrap reflow.
    ///   - rectangular: Whether to preserve all row boundaries.
    public init(terminalColumns: Int, rectangular: Bool = false) {
        self.terminalColumns = terminalColumns
        self.rectangular = rectangular
    }

    /// Trims, dedents, and reflows selected plain text.
    ///
    /// - Parameter text: Selection text with soft wraps already joined.
    /// - Returns: Unwrapped plain text, with code indentation preserved.
    public func unwrappedText(_ text: String) -> String {
        var fence: Substring = ""
        var protected: [Bool] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            var line = String(raw.reversed().drop(while: \.isWhitespace).reversed())
            let content = line.drop(while: \.isWhitespace)
            let delimiter = fenceDelimiter(content)
            let inside = !fence.isEmpty
            protected.append(inside || !delimiter.isEmpty)
            if inside {
                if delimiter.first == fence.first, delimiter.count >= fence.count,
                   content.dropFirst(delimiter.count).allSatisfy(\.isWhitespace) {
                    fence = ""
                }
            } else if !delimiter.isEmpty {
                fence = delimiter
            } else if let first = content.first, "⏺●⎿✻✳✶✢✽".contains(first),
                      content.dropFirst().first == " " {
                let index = line.index(line.startIndex, offsetBy: line.count - content.count)
                line.replaceSubrange(index...index, with: " ")
            }
            return line
        }
        let widths = lines.map(width)
        let widest = widths.max() ?? 0
        let nonblank = lines.indices.filter { !lines[$0].isEmpty }
        let restIndent = nonblank.dropFirst().map { indent(lines[$0]) }.min()
        let partialFirst = nonblank.first.map {
            indent(lines[$0]) < (restIndent ?? 0)
                && !startsStructure(lines[$0].drop(while: \.isWhitespace))
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
            let joins = canReflow && index > 0 && !protected[index] && !protected[index - 1]
                && !line.isEmpty && !dedented[index - 1].isEmpty
                && !endsWithContinuation(dedented[index - 1])
                && !startsStructure(content)
                && indent(line) == continuationIndent
                && !isColumnar(line) && !isColumnar(dedented[index - 1])
                && ((partialFirst && index - 1 == nonblank.first)
                    || widths[index - 1] + 1 + width(String(content.prefix(while: { !$0.isWhitespace }))) > widest)
            if joins, let previous = result.popLast() {
                let token = dedented[index - 1].split(whereSeparator: \.isWhitespace).last ?? ""
                let splitToken = widths[index - 1] == widest
                    && (token.contains("://") || token.hasPrefix("www.") || token.contains("/"))
                result.append(previous + (splitToken ? "" : " ") + content)
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

    private func listPrefixLength(_ content: Substring) -> Int {
        if let first = content.first, "-*+•".contains(first), content.dropFirst().first == " " {
            return content.prefix(2).count + content.dropFirst(2).prefix(while: { $0 == " " }).count
        }
        let digits = content.prefix(while: \.isNumber)
        let rest = content.dropFirst(digits.count)
        if !digits.isEmpty, rest.hasPrefix(". ") || rest.hasPrefix(") ") {
            return digits.count + 2 + rest.dropFirst(2).prefix(while: { $0 == " " }).count
        }
        return 0
    }

    private func startsStructure(_ content: Substring) -> Bool {
        if listPrefixLength(content) > 0 || !fenceDelimiter(content).isEmpty { return true }
        if let first = content.first, "#>|".contains(first) { return true }
        if content.hasPrefix("$ ") { return true }
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
