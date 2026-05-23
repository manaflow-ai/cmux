import CoreGraphics
import CoreText
import Foundation

public struct CMUXMarkdownDocument: Equatable, Sendable {
    public var blocks: [CMUXMarkdownBlock]

    public init(blocks: [CMUXMarkdownBlock]) {
        self.blocks = blocks
    }
}

public enum CMUXMarkdownBlockKind: Equatable, Hashable, Sendable {
    case paragraph
    case heading(level: Int)
    case unorderedListItem(depth: Int, taskState: CMUXMarkdownTaskState?)
    case orderedListItem(depth: Int, number: Int)
    case blockQuote(depth: Int)
    case codeBlock(language: String?)
    case table
    case thematicBreak
}

public enum CMUXMarkdownTaskState: Equatable, Hashable, Sendable {
    case unchecked
    case checked
}

public enum CMUXMarkdownTableAlignment: Equatable, Hashable, Sendable {
    case none
    case left
    case center
    case right
}

public struct CMUXMarkdownTableCell: Equatable, Sendable {
    public var markdown: String
    public var text: String
    public var inlineSpans: [CMUXMarkdownInlineSpan]

    public init(
        markdown: String,
        text: String,
        inlineSpans: [CMUXMarkdownInlineSpan] = []
    ) {
        self.markdown = markdown
        self.text = text
        self.inlineSpans = inlineSpans
    }
}

public struct CMUXMarkdownTableRow: Equatable, Sendable {
    public var cells: [CMUXMarkdownTableCell]
    public var isHeader: Bool

    public init(cells: [CMUXMarkdownTableCell], isHeader: Bool) {
        self.cells = cells
        self.isHeader = isHeader
    }
}

public struct CMUXMarkdownTable: Equatable, Sendable {
    public var alignments: [CMUXMarkdownTableAlignment]
    public var rows: [CMUXMarkdownTableRow]

    public init(
        alignments: [CMUXMarkdownTableAlignment],
        rows: [CMUXMarkdownTableRow]
    ) {
        self.alignments = alignments
        self.rows = rows
    }
}

public struct CMUXMarkdownBlock: Equatable, Sendable {
    public var kind: CMUXMarkdownBlockKind
    public var text: String
    public var inlineSpans: [CMUXMarkdownInlineSpan]
    public var table: CMUXMarkdownTable?

    public init(
        kind: CMUXMarkdownBlockKind,
        text: String,
        inlineSpans: [CMUXMarkdownInlineSpan] = [],
        table: CMUXMarkdownTable? = nil
    ) {
        self.kind = kind
        self.text = text
        self.inlineSpans = inlineSpans
        self.table = table
    }
}

public struct CMUXMarkdownInlineStyles: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let emphasis = CMUXMarkdownInlineStyles(rawValue: 1 << 0)
    public static let strong = CMUXMarkdownInlineStyles(rawValue: 1 << 1)
    public static let code = CMUXMarkdownInlineStyles(rawValue: 1 << 2)
    public static let strikethrough = CMUXMarkdownInlineStyles(rawValue: 1 << 3)
    public static let link = CMUXMarkdownInlineStyles(rawValue: 1 << 4)
}

public struct CMUXMarkdownInlineSpan: Equatable, Sendable {
    public var range: NSRange
    public var styles: CMUXMarkdownInlineStyles
    public var linkDestination: String?

    public init(
        range: NSRange,
        styles: CMUXMarkdownInlineStyles,
        linkDestination: String? = nil
    ) {
        self.range = range
        self.styles = styles
        self.linkDestination = linkDestination
    }
}

public struct CMUXMarkdownParser: Sendable {
    public init() {}

    public func parse(_ source: String) -> CMUXMarkdownDocument {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        var blocks: [CMUXMarkdownBlock] = []
        var index = 0

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let fence = fencedCodeStart(line) {
                let start = index + 1
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    if isFenceEnd(lines[index], marker: fence.marker) {
                        index += 1
                        break
                    }
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(
                    CMUXMarkdownBlock(
                        kind: .codeBlock(language: fence.language),
                        text: codeLines.joined(separator: "\n")
                    )
                )
                if index == start, index >= lines.count {
                    break
                }
                continue
            }

            if let table = parseTable(lines: lines, index: index) {
                blocks.append(table.block)
                index = table.nextIndex
                continue
            }

            if isThematicBreak(line) {
                blocks.append(CMUXMarkdownBlock(kind: .thematicBreak, text: ""))
                index += 1
                continue
            }

            if let heading = parseHeading(line) {
                blocks.append(inlineBlock(kind: .heading(level: heading.level), text: heading.text))
                index += 1
                continue
            }

            if let quote = parseQuoteLine(line) {
                var quoteLines = [quote.text]
                let depth = quote.depth
                index += 1
                while index < lines.count, let next = parseQuoteLine(lines[index]), next.depth == depth {
                    quoteLines.append(next.text)
                    index += 1
                }
                blocks.append(inlineBlock(kind: .blockQuote(depth: depth), text: quoteLines.joined(separator: "\n")))
                continue
            }

            if let listItem = parseListItem(line) {
                blocks.append(inlineBlock(kind: listItem.kind, text: listItem.text))
                index += 1
                continue
            }

            var paragraphLines = [line]
            index += 1
            while index < lines.count {
                let candidate = lines[index]
                if candidate.trimmingCharacters(in: .whitespaces).isEmpty ||
                    fencedCodeStart(candidate) != nil ||
                    parseTable(lines: lines, index: index) != nil ||
                    isThematicBreak(candidate) ||
                    parseHeading(candidate) != nil ||
                    parseQuoteLine(candidate) != nil ||
                    parseListItem(candidate) != nil {
                    break
                }
                paragraphLines.append(candidate)
                index += 1
            }

            blocks.append(inlineBlock(kind: .paragraph, text: paragraphLines.joined(separator: "\n")))
        }

        return CMUXMarkdownDocument(blocks: blocks)
    }

    private func inlineBlock(kind: CMUXMarkdownBlockKind, text: String) -> CMUXMarkdownBlock {
        let parsed = CMUXMarkdownInlineParser().parse(text)
        return CMUXMarkdownBlock(kind: kind, text: parsed.text, inlineSpans: parsed.spans)
    }

    private func fencedCodeStart(_ line: String) -> (marker: String, language: String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else { return nil }
        guard let markerCharacter = trimmed.first else { return nil }
        let marker = String(trimmed.prefix { $0 == markerCharacter })
        guard marker.count >= 3 else { return nil }
        let language = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        return (marker, language.isEmpty ? nil : language)
    }

    private func isFenceEnd(_ line: String, marker: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(marker) else { return false }
        return trimmed.allSatisfy { $0 == marker.first || $0 == " " || $0 == "\t" }
    }

    private func isThematicBreak(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let compact = trimmed.filter { $0 != " " && $0 != "\t" }
        guard compact.count >= 3, let first = compact.first, first == "-" || first == "_" || first == "*" else {
            return false
        }
        return compact.allSatisfy { $0 == first }
    }

    private func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let leadingSpaces = line.prefix { $0 == " " }.count
        guard leadingSpaces <= 3 else { return nil }
        let trimmed = line.dropFirst(leadingSpaces)
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let afterHashes = trimmed.dropFirst(hashes)
        guard afterHashes.first == " " || afterHashes.first == "\t" else { return nil }
        let rawText = afterHashes.trimmingCharacters(in: .whitespaces)
        let closingFenceRange = rawText.range(
            of: #"[ \t]+#{1,}[ \t]*$"#,
            options: .regularExpression
        )
        let text: String
        if let closingFenceRange {
            text = String(rawText[..<closingFenceRange.lowerBound])
        } else {
            text = rawText
        }
        return (hashes, text.trimmingCharacters(in: .whitespaces))
    }

    private func parseQuoteLine(_ line: String) -> (depth: Int, text: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == ">" else { return nil }
        var depth = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex, trimmed[index] == ">" {
            depth += 1
            index = trimmed.index(after: index)
            if index < trimmed.endIndex, trimmed[index] == " " {
                index = trimmed.index(after: index)
            }
        }
        return (max(1, depth), String(trimmed[index...]))
    }

    private func parseListItem(_ line: String) -> (kind: CMUXMarkdownBlockKind, text: String)? {
        let indent = line.prefix { $0 == " " }.count
        let depth = indent / 2
        let trimmed = line.dropFirst(indent)
        guard !trimmed.isEmpty else { return nil }

        if let first = trimmed.first, first == "-" || first == "*" || first == "+" {
            let afterMarker = trimmed.dropFirst()
            guard afterMarker.first == " " || afterMarker.first == "\t" else { return nil }
            let body = afterMarker.trimmingCharacters(in: .whitespaces)
            if body.hasPrefix("[ ] ") {
                return (.unorderedListItem(depth: depth, taskState: .unchecked), String(body.dropFirst(4)))
            }
            if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
                return (.unorderedListItem(depth: depth, taskState: .checked), String(body.dropFirst(4)))
            }
            return (.unorderedListItem(depth: depth, taskState: nil), body)
        }

        var digits = ""
        var cursor = trimmed.startIndex
        while cursor < trimmed.endIndex, trimmed[cursor].isNumber {
            digits.append(trimmed[cursor])
            cursor = trimmed.index(after: cursor)
        }
        guard !digits.isEmpty,
              cursor < trimmed.endIndex,
              trimmed[cursor] == "." || trimmed[cursor] == ")" else {
            return nil
        }
        cursor = trimmed.index(after: cursor)
        guard cursor < trimmed.endIndex, trimmed[cursor] == " " || trimmed[cursor] == "\t" else { return nil }
        let text = trimmed[cursor...].trimmingCharacters(in: .whitespaces)
        return (.orderedListItem(depth: depth, number: Int(digits) ?? 1), text)
    }

    private func parseTable(lines: [String], index: Int) -> (block: CMUXMarkdownBlock, nextIndex: Int)? {
        guard index + 1 < lines.count,
              lineCanStartTable(lines[index]),
              let alignments = parseTableDelimiter(lines[index + 1]) else {
            return nil
        }

        let headerCells = splitTableCells(lines[index])
        guard !headerCells.isEmpty else { return nil }

        var rawRows: [[String]] = [headerCells]
        var cursor = index + 2
        while cursor < lines.count {
            let line = lines[cursor]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            guard lineCanStartTable(line), parseTableDelimiter(line) == nil else {
                break
            }
            rawRows.append(splitTableCells(line))
            cursor += 1
        }

        let columnCount = max(rawRows.map(\.count).max() ?? 0, alignments.count)
        guard columnCount > 0 else { return nil }

        let normalizedAlignments = alignments.padded(to: columnCount, with: .none)
        let inlineParser = CMUXMarkdownInlineParser()
        let rows = rawRows.enumerated().map { rowIndex, cells in
            CMUXMarkdownTableRow(
                cells: cells.padded(to: columnCount, with: "").map { markdown in
                    let parsed = inlineParser.parse(markdown)
                    return CMUXMarkdownTableCell(
                        markdown: markdown,
                        text: parsed.text.replacingOccurrences(of: "\n", with: " "),
                        inlineSpans: parsed.spans
                    )
                },
                isHeader: rowIndex == 0
            )
        }

        let table = CMUXMarkdownTable(alignments: normalizedAlignments, rows: rows)
        let rendered = renderTablePlainText(table)
        return (
            CMUXMarkdownBlock(
                kind: .table,
                text: rendered.text,
                inlineSpans: rendered.spans,
                table: table
            ),
            cursor
        )
    }

    private func lineCanStartTable(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return trimmed.contains("|")
    }

    private func parseTableDelimiter(_ line: String) -> [CMUXMarkdownTableAlignment]? {
        guard lineCanStartTable(line) else { return nil }
        let cells = splitTableCells(line)
        guard !cells.isEmpty else { return nil }
        var alignments: [CMUXMarkdownTableAlignment] = []
        alignments.reserveCapacity(cells.count)
        for cell in cells {
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 3 else { return nil }
            let startsWithColon = trimmed.first == ":"
            let endsWithColon = trimmed.last == ":"
            let marker = trimmed
                .drop(while: { $0 == ":" })
                .dropLast(endsWithColon ? 1 : 0)
            guard marker.count >= 3, marker.allSatisfy({ $0 == "-" }) else {
                return nil
            }
            switch (startsWithColon, endsWithColon) {
            case (true, true):
                alignments.append(.center)
            case (false, true):
                alignments.append(.right)
            case (true, false):
                alignments.append(.left)
            case (false, false):
                alignments.append(.none)
            }
        }
        return alignments
    }

    private func splitTableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.first == "|" {
            trimmed.removeFirst()
        }
        if trimmed.last == "|", !hasEscapedTrailingPipe(trimmed) {
            trimmed.removeLast()
        }

        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for character in trimmed {
            if escaped {
                if character == "|" {
                    current.append(character)
                } else {
                    current.append("\\")
                    current.append(character)
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "`" {
                inCode.toggle()
                current.append(character)
                continue
            }
            if character == "|", !inCode {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current.removeAll(keepingCapacity: true)
                continue
            }
            current.append(character)
        }
        if escaped {
            current.append("\\")
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private func hasEscapedTrailingPipe(_ line: String) -> Bool {
        guard line.last == "|" else { return false }
        var slashCount = 0
        var index = line.index(before: line.endIndex)
        while index > line.startIndex {
            let previous = line.index(before: index)
            guard line[previous] == "\\" else { break }
            slashCount += 1
            index = previous
        }
        return slashCount % 2 == 1
    }

    private func renderTablePlainText(_ table: CMUXMarkdownTable) -> (text: String, spans: [CMUXMarkdownInlineSpan]) {
        let columnCount = table.alignments.count
        let widths = (0..<columnCount).map { column in
            max(
                3,
                table.rows.map { row in
                    row.cells[safe: column]?.text.utf16.count ?? 0
                }.max() ?? 0
            )
        }

        var text = ""
        var spans: [CMUXMarkdownInlineSpan] = []

        func appendRow(_ row: CMUXMarkdownTableRow) {
            for column in 0..<columnCount {
                if column > 0 {
                    text += " | "
                }
                let cell = row.cells[safe: column] ?? CMUXMarkdownTableCell(markdown: "", text: "")
                let aligned = alignTableCell(cell.text, width: widths[column], alignment: table.alignments[column])
                let cellTextOffset = leadingPaddingCount(in: aligned)
                let cellStart = text.utf16.count + cellTextOffset
                if row.isHeader, !cell.text.isEmpty {
                    spans.append(
                        CMUXMarkdownInlineSpan(
                            range: NSRange(location: cellStart, length: cell.text.utf16.count),
                            styles: .strong
                        )
                    )
                }
                for span in cell.inlineSpans {
                    spans.append(span.offset(by: cellStart))
                }
                text += aligned
            }
            if row.isHeader {
                text += "\n"
                text += widths.map { String(repeating: "-", count: $0) }.joined(separator: "-+-")
            }
        }

        for (index, row) in table.rows.enumerated() {
            if index > 0 {
                text += "\n"
            }
            appendRow(row)
        }

        return (text, spans)
    }

    private func alignTableCell(
        _ text: String,
        width: Int,
        alignment: CMUXMarkdownTableAlignment
    ) -> String {
        let length = text.utf16.count
        guard length < width else { return text }
        let padding = width - length
        switch alignment {
        case .right:
            return String(repeating: " ", count: padding) + text
        case .center:
            let left = padding / 2
            let right = padding - left
            return String(repeating: " ", count: left) + text + String(repeating: " ", count: right)
        case .none, .left:
            return text + String(repeating: " ", count: padding)
        }
    }

    private func leadingPaddingCount(in text: String) -> Int {
        text.prefix { $0 == " " }.count
    }
}

private extension Array {
    func padded(to count: Int, with element: Element) -> [Element] {
        guard self.count < count else { return Array(prefix(count)) }
        return self + Array(repeating: element, count: count - self.count)
    }

    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

public struct CMUXMarkdownInlineParser: Sendable {
    private static let escapableCharacters = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    public init() {}

    public func parse(_ source: String) -> (text: String, spans: [CMUXMarkdownInlineSpan]) {
        parseFragment(source, baseStyles: [])
    }

    private func parseFragment(
        _ source: String,
        baseStyles: CMUXMarkdownInlineStyles
    ) -> (text: String, spans: [CMUXMarkdownInlineSpan]) {
        var output = ""
        var spans: [CMUXMarkdownInlineSpan] = []
        var index = source.startIndex

        func appendStyled(_ string: String, styles: CMUXMarkdownInlineStyles, link: String? = nil) {
            let start = output.utf16.count
            let parsed = parseFragment(string, baseStyles: baseStyles.union(styles))
            output += parsed.text
            for span in parsed.spans {
                spans.append(span.offset(by: start))
            }
            let length = output.utf16.count - start
            if length > 0 {
                spans.append(
                    CMUXMarkdownInlineSpan(
                        range: NSRange(location: start, length: length),
                        styles: baseStyles.union(styles),
                        linkDestination: link
                    )
                )
            }
        }

        while index < source.endIndex {
            if source[index] == "\\", let next = source.index(index, offsetBy: 1, limitedBy: source.endIndex), next < source.endIndex {
                if Self.escapableCharacters.contains(source[next]) {
                    output.append(source[next])
                    index = source.index(after: next)
                } else {
                    output.append(source[index])
                    index = source.index(after: index)
                }
                continue
            }

            if source[index] == "`", let close = find("`", in: source, after: source.index(after: index)) {
                let inner = String(source[source.index(after: index)..<close])
                let start = output.utf16.count
                output += inner
                let length = output.utf16.count - start
                if length > 0 {
                    spans.append(
                        CMUXMarkdownInlineSpan(
                            range: NSRange(location: start, length: length),
                            styles: baseStyles.union(.code)
                        )
                    )
                }
                index = source.index(after: close)
                continue
            }

            if hasPrefix("**", in: source, at: index),
               let close = find("**", in: source, after: source.index(index, offsetBy: 2)) {
                appendStyled(String(source[source.index(index, offsetBy: 2)..<close]), styles: .strong)
                index = source.index(close, offsetBy: 2)
                continue
            }

            if hasPrefix("__", in: source, at: index),
               canOpenUnderscoreDelimiter("__", in: source, at: index),
               let close = findClosingUnderscoreDelimiter("__", in: source, after: source.index(index, offsetBy: 2)) {
                appendStyled(String(source[source.index(index, offsetBy: 2)..<close]), styles: .strong)
                index = source.index(close, offsetBy: 2)
                continue
            }

            if hasPrefix("~~", in: source, at: index),
               let close = find("~~", in: source, after: source.index(index, offsetBy: 2)) {
                appendStyled(String(source[source.index(index, offsetBy: 2)..<close]), styles: .strikethrough)
                index = source.index(close, offsetBy: 2)
                continue
            }

            if source[index] == "*",
               let close = find("*", in: source, after: source.index(after: index)) {
                appendStyled(String(source[source.index(after: index)..<close]), styles: .emphasis)
                index = source.index(after: close)
                continue
            }

            if source[index] == "_",
               canOpenUnderscoreDelimiter("_", in: source, at: index),
               let close = findClosingUnderscoreDelimiter("_", in: source, after: source.index(after: index)) {
                appendStyled(String(source[source.index(after: index)..<close]), styles: .emphasis)
                index = source.index(after: close)
                continue
            }

            if source[index] == "[",
               let labelEnd = find("]", in: source, after: source.index(after: index)),
               let openParen = source.index(labelEnd, offsetBy: 1, limitedBy: source.endIndex),
               openParen < source.endIndex,
               source[openParen] == "(",
               let closeParen = findLinkDestinationCloseParen(in: source, after: source.index(after: openParen)) {
                let label = String(source[source.index(after: index)..<labelEnd])
                let destination = String(source[source.index(after: openParen)..<closeParen])
                appendStyled(label, styles: .link, link: destination)
                index = source.index(after: closeParen)
                continue
            }

            output.append(source[index])
            index = source.index(after: index)
        }

        return (output, normalized(spans: spans, textLength: output.utf16.count))
    }

    private func hasPrefix(_ marker: String, in source: String, at index: String.Index) -> Bool {
        source[index...].hasPrefix(marker)
    }

    private func find(_ marker: String, in source: String, after index: String.Index) -> String.Index? {
        source.range(of: marker, range: index..<source.endIndex)?.lowerBound
    }

    private func findLinkDestinationCloseParen(in source: String, after index: String.Index) -> String.Index? {
        var cursor = index
        var nestedDepth = 0
        var escaped = false
        while cursor < source.endIndex {
            let character = source[cursor]
            if escaped {
                escaped = false
                cursor = source.index(after: cursor)
                continue
            }
            if character == "\\" {
                escaped = true
                cursor = source.index(after: cursor)
                continue
            }
            if character == "(" {
                nestedDepth += 1
            } else if character == ")" {
                if nestedDepth == 0 {
                    return cursor
                }
                nestedDepth -= 1
            }
            cursor = source.index(after: cursor)
        }
        return nil
    }

    private func findClosingUnderscoreDelimiter(
        _ marker: String,
        in source: String,
        after index: String.Index
    ) -> String.Index? {
        var cursor = index
        while let range = source.range(of: marker, range: cursor..<source.endIndex) {
            if canCloseUnderscoreDelimiter(marker, in: source, at: range.lowerBound) {
                return range.lowerBound
            }
            cursor = range.upperBound
        }
        return nil
    }

    private func canOpenUnderscoreDelimiter(
        _ marker: String,
        in source: String,
        at index: String.Index
    ) -> Bool {
        guard let after = source.index(index, offsetBy: marker.count, limitedBy: source.endIndex),
              after < source.endIndex,
              !source[after].isWhitespace else {
            return false
        }
        if index > source.startIndex {
            let previous = source[source.index(before: index)]
            if isIdentifierCharacter(previous) {
                return false
            }
        }
        return true
    }

    private func canCloseUnderscoreDelimiter(
        _ marker: String,
        in source: String,
        at index: String.Index
    ) -> Bool {
        guard index > source.startIndex else { return false }
        let previous = source[source.index(before: index)]
        guard !previous.isWhitespace else { return false }
        guard let after = source.index(index, offsetBy: marker.count, limitedBy: source.endIndex) else {
            return true
        }
        if after < source.endIndex, isIdentifierCharacter(source[after]) {
            return false
        }
        return true
    }

    private func isIdentifierCharacter(_ character: Character) -> Bool {
        character == "_" || character.isLetter || character.isNumber
    }

    private func normalized(spans: [CMUXMarkdownInlineSpan], textLength: Int) -> [CMUXMarkdownInlineSpan] {
        spans.compactMap { span in
            let location = min(max(0, span.range.location), textLength)
            let upper = min(max(location, span.range.upperBound), textLength)
            guard upper > location else { return nil }
            return CMUXMarkdownInlineSpan(
                range: NSRange(location: location, length: upper - location),
                styles: span.styles,
                linkDestination: span.linkDestination
            )
        }
    }
}

private extension CMUXMarkdownInlineSpan {
    func offset(by offset: Int) -> CMUXMarkdownInlineSpan {
        CMUXMarkdownInlineSpan(
            range: NSRange(location: range.location + offset, length: range.length),
            styles: styles,
            linkDestination: linkDestination
        )
    }
}

public struct CMUXMarkdownRenderedText {
    public var plainText: String
    public var attributedString: CFAttributedString

    public init(plainText: String, attributedString: CFAttributedString) {
        self.plainText = plainText
        self.attributedString = attributedString
    }
}

public struct CMUXMarkdownCoreTextTheme {
    public var baseFont: CTFont
    public var monospacedFont: CTFont
    public var foregroundColor: CGColor
    public var mutedColor: CGColor
    public var linkColor: CGColor
    public var codeColor: CGColor
    public var paragraphSpacing: CGFloat
    public var lineSpacing: CGFloat

    public init(
        baseFont: CTFont,
        monospacedFont: CTFont,
        foregroundColor: CGColor,
        mutedColor: CGColor,
        linkColor: CGColor,
        codeColor: CGColor,
        paragraphSpacing: CGFloat = 8,
        lineSpacing: CGFloat = 3
    ) {
        self.baseFont = baseFont
        self.monospacedFont = monospacedFont
        self.foregroundColor = foregroundColor
        self.mutedColor = mutedColor
        self.linkColor = linkColor
        self.codeColor = codeColor
        self.paragraphSpacing = paragraphSpacing
        self.lineSpacing = lineSpacing
    }

    public static func `default`() -> CMUXMarkdownCoreTextTheme {
        let baseFont = CTFontCreateUIFontForLanguage(.system, 15, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 15, nil)
        let monoFont = CTFontCreateUIFontForLanguage(.userFixedPitch, 14, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, 14, nil)
        return CMUXMarkdownCoreTextTheme(
            baseFont: baseFont,
            monospacedFont: monoFont,
            foregroundColor: CGColor(red: 0.92, green: 0.93, blue: 0.90, alpha: 1),
            mutedColor: CGColor(red: 0.55, green: 0.57, blue: 0.54, alpha: 1),
            linkColor: CGColor(red: 0.48, green: 0.68, blue: 1.0, alpha: 1),
            codeColor: CGColor(red: 0.88, green: 0.72, blue: 0.48, alpha: 1)
        )
    }
}

public struct CMUXMarkdownCoreTextRenderer {
    public var theme: CMUXMarkdownCoreTextTheme

    public init(theme: CMUXMarkdownCoreTextTheme = .default()) {
        self.theme = theme
    }

    public func render(_ document: CMUXMarkdownDocument) -> CMUXMarkdownRenderedText {
        let output = NSMutableAttributedString()
        var plainTextParts: [String] = []
        plainTextParts.reserveCapacity(document.blocks.count * 2)
        var attributeCache: [CMUXMarkdownBlockKind: [NSAttributedString.Key: Any]] = [:]

        func cachedAttributes(for kind: CMUXMarkdownBlockKind) -> [NSAttributedString.Key: Any] {
            if let cached = attributeCache[kind] {
                return cached
            }
            let attributes = attributes(for: kind)
            attributeCache[kind] = attributes
            return attributes
        }

        for (index, block) in document.blocks.enumerated() {
            let blockStart = output.length
            let rendered = renderedText(for: block)
            plainTextParts.append(rendered.text)
            output.append(
                NSAttributedString(
                    string: rendered.text,
                    attributes: cachedAttributes(for: block.kind)
                )
            )

            for span in block.inlineSpans {
                apply(
                    span: span,
                    blockKind: block.kind,
                    blockStart: blockStart + inlineTextOffset(for: block.kind),
                    to: output
                )
            }

            let separator = index == document.blocks.count - 1 ? "" : rendered.separator
            if !separator.isEmpty {
                plainTextParts.append(separator)
                output.append(NSAttributedString(string: separator, attributes: cachedAttributes(for: .paragraph)))
            }
        }

        let plainText = plainTextParts.joined()
        if plainText.isEmpty {
            let attributes = attributes(for: .paragraph)
            return CMUXMarkdownRenderedText(
                plainText: " ",
                attributedString: NSAttributedString(string: " ", attributes: attributes) as CFAttributedString
            )
        }

        return CMUXMarkdownRenderedText(plainText: plainText, attributedString: output as CFAttributedString)
    }

    public func render(_ markdown: String) -> CMUXMarkdownRenderedText {
        render(CMUXMarkdownParser().parse(markdown))
    }

    private func renderedText(for block: CMUXMarkdownBlock) -> (text: String, separator: String) {
        switch block.kind {
        case .paragraph, .heading:
            return (block.text, "\n\n")
        case .unorderedListItem(let depth, let taskState):
            let indent = String(repeating: "  ", count: max(0, depth))
            let checkbox: String
            switch taskState {
            case .checked:
                checkbox = "[x] "
            case .unchecked:
                checkbox = "[ ] "
            case nil:
                checkbox = ""
            }
            return ("\(indent)- \(checkbox)\(block.text)", "\n")
        case .orderedListItem(let depth, let number):
            let indent = String(repeating: "  ", count: max(0, depth))
            return ("\(indent)\(number). \(block.text)", "\n")
        case .blockQuote(let depth):
            let prefix = String(repeating: "> ", count: max(1, depth))
            return (block.text.split(separator: "\n", omittingEmptySubsequences: false).map { "\(prefix)\($0)" }.joined(separator: "\n"), "\n\n")
        case .codeBlock:
            return (block.text, "\n\n")
        case .table:
            return (block.text, "\n\n")
        case .thematicBreak:
            return ("------------------------------", "\n\n")
        }
    }

    private func inlineTextOffset(for kind: CMUXMarkdownBlockKind) -> Int {
        switch kind {
        case .unorderedListItem(let depth, let taskState):
            let indentLength = max(0, depth) * 2
            let checkboxLength: Int
            switch taskState {
            case .checked, .unchecked:
                checkboxLength = 4
            case nil:
                checkboxLength = 0
            }
            return indentLength + 2 + checkboxLength
        case .orderedListItem(let depth, let number):
            return max(0, depth) * 2 + "\(number). ".utf16.count
        case .paragraph, .heading, .blockQuote, .codeBlock, .table, .thematicBreak:
            return 0
        }
    }

    private func attributes(for kind: CMUXMarkdownBlockKind) -> [NSAttributedString.Key: Any] {
        let font: CTFont
        let color: CGColor
        let paragraphStyle: CTParagraphStyle

        switch kind {
        case .heading(let level):
            font = headingFont(level: level)
            color = theme.foregroundColor
            paragraphStyle = makeParagraphStyle(paragraphSpacing: theme.paragraphSpacing + CGFloat(max(0, 7 - level)), lineSpacing: theme.lineSpacing)
        case .codeBlock:
            font = theme.monospacedFont
            color = theme.codeColor
            paragraphStyle = makeParagraphStyle(paragraphSpacing: theme.paragraphSpacing, lineSpacing: 2)
        case .table:
            font = theme.monospacedFont
            color = theme.foregroundColor
            paragraphStyle = makeParagraphStyle(paragraphSpacing: theme.paragraphSpacing + 2, lineSpacing: 2)
        case .blockQuote:
            font = theme.baseFont
            color = theme.mutedColor
            paragraphStyle = makeParagraphStyle(paragraphSpacing: theme.paragraphSpacing, lineSpacing: theme.lineSpacing)
        case .thematicBreak:
            font = theme.monospacedFont
            color = theme.mutedColor
            paragraphStyle = makeParagraphStyle(paragraphSpacing: theme.paragraphSpacing, lineSpacing: theme.lineSpacing)
        case .unorderedListItem(let depth, _), .orderedListItem(let depth, _):
            font = theme.baseFont
            color = theme.foregroundColor
            let indent = CGFloat(max(0, depth)) * 18
            paragraphStyle = makeParagraphStyle(
                firstLineHeadIndent: indent,
                headIndent: indent + 18,
                paragraphSpacing: 3,
                lineSpacing: theme.lineSpacing
            )
        case .paragraph:
            font = theme.baseFont
            color = theme.foregroundColor
            paragraphStyle = makeParagraphStyle(paragraphSpacing: theme.paragraphSpacing, lineSpacing: theme.lineSpacing)
        }

        return [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
        ]
    }

    private func apply(
        span: CMUXMarkdownInlineSpan,
        blockKind: CMUXMarkdownBlockKind,
        blockStart: Int,
        to output: NSMutableAttributedString
    ) {
        let range = NSRange(location: blockStart + span.range.location, length: span.range.length)
        guard range.location >= 0, range.upperBound <= output.length, range.length > 0 else { return }

        if span.styles.contains(.code) {
            output.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: theme.monospacedFont, range: range)
            output.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: theme.codeColor, range: range)
            return
        }

        var symbolicTraits: CTFontSymbolicTraits = []
        if span.styles.contains(.strong) {
            symbolicTraits.insert(.boldTrait)
        }
        if span.styles.contains(.emphasis) {
            symbolicTraits.insert(.italicTrait)
        }
        let baseFont = blockKind == .table ? theme.monospacedFont : theme.baseFont
        if !symbolicTraits.isEmpty,
           let font = CTFontCreateCopyWithSymbolicTraits(baseFont, 0, nil, symbolicTraits, symbolicTraits) {
            output.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String), value: font, range: range)
        }
        if span.styles.contains(.link) {
            output.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: theme.linkColor, range: range)
            output.addAttribute(NSAttributedString.Key(kCTUnderlineStyleAttributeName as String), value: CTUnderlineStyle.single.rawValue, range: range)
        }
        if span.styles.contains(.strikethrough) {
            output.addAttribute(NSAttributedString.Key.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
    }

    private func headingFont(level: Int) -> CTFont {
        let baseSize = CTFontGetSize(theme.baseFont)
        let multiplier: CGFloat
        switch level {
        case 1:
            multiplier = 1.85
        case 2:
            multiplier = 1.55
        case 3:
            multiplier = 1.30
        case 4:
            multiplier = 1.15
        default:
            multiplier = 1.0
        }
        return CTFontCreateCopyWithSymbolicTraits(
            theme.baseFont,
            max(baseSize, baseSize * multiplier),
            nil,
            .boldTrait,
            .boldTrait
        ) ?? theme.baseFont
    }

    private func makeParagraphStyle(
        firstLineHeadIndent: CGFloat = 0,
        headIndent: CGFloat = 0,
        paragraphSpacing: CGFloat,
        lineSpacing: CGFloat
    ) -> CTParagraphStyle {
        var alignment = CTTextAlignment.left
        var firstLineHeadIndent = firstLineHeadIndent
        var headIndent = headIndent
        var paragraphSpacing = paragraphSpacing
        var lineSpacing = lineSpacing

        return withUnsafePointer(to: &alignment) { alignmentPointer in
            withUnsafePointer(to: &firstLineHeadIndent) { firstLineHeadIndentPointer in
                withUnsafePointer(to: &headIndent) { headIndentPointer in
                    withUnsafePointer(to: &paragraphSpacing) { paragraphSpacingPointer in
                        withUnsafePointer(to: &lineSpacing) { lineSpacingPointer in
                            var settings = [
                                CTParagraphStyleSetting(
                                    spec: .alignment,
                                    valueSize: MemoryLayout<CTTextAlignment>.size,
                                    value: alignmentPointer
                                ),
                                CTParagraphStyleSetting(
                                    spec: .firstLineHeadIndent,
                                    valueSize: MemoryLayout<CGFloat>.size,
                                    value: firstLineHeadIndentPointer
                                ),
                                CTParagraphStyleSetting(
                                    spec: .headIndent,
                                    valueSize: MemoryLayout<CGFloat>.size,
                                    value: headIndentPointer
                                ),
                                CTParagraphStyleSetting(
                                    spec: .paragraphSpacing,
                                    valueSize: MemoryLayout<CGFloat>.size,
                                    value: paragraphSpacingPointer
                                ),
                                CTParagraphStyleSetting(
                                    spec: .lineSpacingAdjustment,
                                    valueSize: MemoryLayout<CGFloat>.size,
                                    value: lineSpacingPointer
                                ),
                            ]
                            return CTParagraphStyleCreate(&settings, settings.count)
                        }
                    }
                }
            }
        }
    }
}

#if canImport(AppKit)
import AppKit

public extension NSAttributedString.Key {
    static let cmuxMarkdownCodeBlockID = NSAttributedString.Key("CMUXMarkdownCodeBlockID")
    static let cmuxMarkdownCodeBlockBackgroundColor = NSAttributedString.Key("CMUXMarkdownCodeBlockBackgroundColor")
    static let cmuxMarkdownCodeBlockBorderColor = NSAttributedString.Key("CMUXMarkdownCodeBlockBorderColor")
    static let cmuxMarkdownCodeBlockCopyText = NSAttributedString.Key("CMUXMarkdownCodeBlockCopyText")
}

public struct CMUXMarkdownAppKitTheme {
    public var baseFont: NSFont
    public var monospacedFont: NSFont
    public var codeBlockLanguageFont: NSFont
    public var foregroundColor: NSColor
    public var mutedColor: NSColor
    public var linkColor: NSColor
    public var codeColor: NSColor
    public var codeBlockForegroundColor: NSColor
    public var codeBlockBackgroundColor: NSColor
    public var codeBlockBorderColor: NSColor
    public var codeBlockLanguageColor: NSColor
    public var codeBlockKeywordColor: NSColor
    public var codeBlockTypeColor: NSColor
    public var codeBlockCommentColor: NSColor
    public var codeBlockStringColor: NSColor
    public var tableHeaderBackgroundColor: NSColor
    public var tableRowBackgroundColor: NSColor
    public var tableAlternateRowBackgroundColor: NSColor
    public var tableBorderColor: NSColor

    public init(
        baseFont: NSFont = .systemFont(ofSize: 14),
        monospacedFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular),
        codeBlockLanguageFont: NSFont = .systemFont(ofSize: 12, weight: .medium),
        foregroundColor: NSColor = .labelColor,
        mutedColor: NSColor = .secondaryLabelColor,
        linkColor: NSColor = .linkColor,
        codeColor: NSColor = .secondaryLabelColor,
        codeBlockForegroundColor: NSColor = .labelColor,
        codeBlockBackgroundColor: NSColor = .controlBackgroundColor,
        codeBlockBorderColor: NSColor = .separatorColor,
        codeBlockLanguageColor: NSColor = .secondaryLabelColor,
        codeBlockKeywordColor: NSColor = .systemBlue,
        codeBlockTypeColor: NSColor = .systemRed,
        codeBlockCommentColor: NSColor = .secondaryLabelColor,
        codeBlockStringColor: NSColor = .systemGreen,
        tableHeaderBackgroundColor: NSColor = .controlAccentColor.withAlphaComponent(0.16),
        tableRowBackgroundColor: NSColor = .controlBackgroundColor.withAlphaComponent(0.70),
        tableAlternateRowBackgroundColor: NSColor = .controlBackgroundColor.withAlphaComponent(0.42),
        tableBorderColor: NSColor = .separatorColor
    ) {
        self.baseFont = baseFont
        self.monospacedFont = monospacedFont
        self.codeBlockLanguageFont = codeBlockLanguageFont
        self.foregroundColor = foregroundColor
        self.mutedColor = mutedColor
        self.linkColor = linkColor
        self.codeColor = codeColor
        self.codeBlockForegroundColor = codeBlockForegroundColor
        self.codeBlockBackgroundColor = codeBlockBackgroundColor
        self.codeBlockBorderColor = codeBlockBorderColor
        self.codeBlockLanguageColor = codeBlockLanguageColor
        self.codeBlockKeywordColor = codeBlockKeywordColor
        self.codeBlockTypeColor = codeBlockTypeColor
        self.codeBlockCommentColor = codeBlockCommentColor
        self.codeBlockStringColor = codeBlockStringColor
        self.tableHeaderBackgroundColor = tableHeaderBackgroundColor
        self.tableRowBackgroundColor = tableRowBackgroundColor
        self.tableAlternateRowBackgroundColor = tableAlternateRowBackgroundColor
        self.tableBorderColor = tableBorderColor
    }
}

public struct CMUXMarkdownAppKitRenderer {
    public var theme: CMUXMarkdownAppKitTheme

    public init(theme: CMUXMarkdownAppKitTheme = CMUXMarkdownAppKitTheme()) {
        self.theme = theme
    }

    public func render(_ markdown: String) -> NSAttributedString {
        render(CMUXMarkdownParser().parse(markdown))
    }

    public func render(_ document: CMUXMarkdownDocument) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var attributeCache: [CMUXMarkdownBlockKind: [NSAttributedString.Key: Any]] = [:]

        func cachedAttributes(for kind: CMUXMarkdownBlockKind) -> [NSAttributedString.Key: Any] {
            if let cached = attributeCache[kind] {
                return cached
            }
            let attributes = attributes(for: kind)
            attributeCache[kind] = attributes
            return attributes
        }

        for (index, block) in document.blocks.enumerated() {
            if let table = block.table {
                appendTable(table, to: output)
                if index != document.blocks.count - 1 {
                    output.append(NSAttributedString(string: "\n", attributes: cachedAttributes(for: .paragraph)))
                }
                continue
            }

            if case .codeBlock(let language) = block.kind {
                appendCodeBlockLeadInSpacerIfNeeded(to: output)
                appendCodeBlock(block.text, language: language, to: output)
                if index != document.blocks.count - 1 {
                    output.append(NSAttributedString(string: "\n", attributes: cachedAttributes(for: .paragraph)))
                }
                continue
            }

            let blockStart = output.length
            let rendered = renderedText(for: block)
            output.append(
                NSAttributedString(
                    string: rendered.text,
                    attributes: cachedAttributes(for: block.kind)
                )
            )
            for span in block.inlineSpans {
                apply(
                    span: span,
                    blockKind: block.kind,
                    blockStart: blockStart + inlineTextOffset(for: block.kind),
                    to: output
                )
            }
            if index != document.blocks.count - 1 {
                output.append(NSAttributedString(string: rendered.separator, attributes: cachedAttributes(for: .paragraph)))
            }
        }

        if output.length == 0 {
            output.append(NSAttributedString(string: " ", attributes: attributes(for: .paragraph)))
        }
        return output
    }

    private func appendCodeBlockLeadInSpacerIfNeeded(to output: NSMutableAttributedString) {
        guard output.length > 0 else { return }
        let current = output.string as NSString
        guard current.length > 0, current.substring(from: max(0, current.length - 1)) == "\n" else {
            output.append(NSAttributedString(string: "\n", attributes: attributes(for: .paragraph)))
            return
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        output.append(
            NSAttributedString(
                string: "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 6),
                    .foregroundColor: theme.foregroundColor,
                    .paragraphStyle: paragraph,
                ]
            )
        )
    }

    private func appendTable(_ markdownTable: CMUXMarkdownTable, to output: NSMutableAttributedString) {
        let table = NSTextTable()
        table.numberOfColumns = markdownTable.alignments.count
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)
        table.setWidth(1, type: .absoluteValueType, for: .border)
        table.setBorderColor(theme.tableBorderColor)

        for (rowIndex, row) in markdownTable.rows.enumerated() {
            let normalizedCells = row.cells.padded(
                to: markdownTable.alignments.count,
                with: CMUXMarkdownTableCell(markdown: "", text: "")
            )
            for columnIndex in 0..<markdownTable.alignments.count {
                let cell = normalizedCells[columnIndex]
                let tableBlock = tableCellBlock(
                    table: table,
                    rowIndex: rowIndex,
                    columnIndex: columnIndex,
                    isHeader: row.isHeader
                )
                let attributes = tableCellAttributes(
                    tableBlock: tableBlock,
                    row: row
                )
                let start = output.length
                let cellText = cell.text.isEmpty ? " " : cell.text
                output.append(NSAttributedString(string: cellText + "\n", attributes: attributes))
                for span in cell.inlineSpans {
                    apply(span: span, blockKind: .table, blockStart: start, to: output)
                }
            }
        }
    }

    private func appendCodeBlock(_ code: String, language: String?, to output: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 16
        paragraph.headIndent = 16
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacingBefore = 0
        paragraph.paragraphSpacing = 0

        let blockStart = output.length
        let languageLabel = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCode = code.hasSuffix("\n") ? code : code + "\n"
        let rendered: String
        if let languageLabel, !languageLabel.isEmpty {
            rendered = languageLabel.lowercased() + "\n" + normalizedCode
        } else {
            rendered = normalizedCode
        }

        output.append(
            NSAttributedString(
                string: rendered,
                attributes: [
                    .font: theme.monospacedFont,
                    .foregroundColor: theme.codeBlockForegroundColor,
                    .paragraphStyle: paragraph,
                    .cmuxMarkdownCodeBlockID: blockStart,
                    .cmuxMarkdownCodeBlockBackgroundColor: theme.codeBlockBackgroundColor,
                    .cmuxMarkdownCodeBlockBorderColor: theme.codeBlockBorderColor,
                    .cmuxMarkdownCodeBlockCopyText: code,
                ]
            )
        )

        if let languageLabel, !languageLabel.isEmpty {
            let languageParagraph = paragraph.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            languageParagraph.firstLineHeadIndent = 16
            languageParagraph.headIndent = 16
            languageParagraph.lineSpacing = 0
            languageParagraph.paragraphSpacingBefore = 0
            languageParagraph.paragraphSpacing = 8
            let labelRange = NSRange(location: blockStart, length: languageLabel.utf16.count)
            let labelParagraphRange = NSRange(location: blockStart, length: languageLabel.utf16.count + 1)
            output.addAttribute(.paragraphStyle, value: languageParagraph, range: labelParagraphRange)
            output.addAttributes(
                [
                    .font: theme.codeBlockLanguageFont,
                    .foregroundColor: theme.codeBlockLanguageColor,
                ],
                range: labelRange
            )
            highlightCode(
                code,
                language: languageLabel,
                blockStart: blockStart + languageLabel.utf16.count + 1,
                in: output
            )
        } else {
            highlightCode(code, language: nil, blockStart: blockStart, in: output)
        }
    }

    private func tableCellBlock(
        table: NSTextTable,
        rowIndex: Int,
        columnIndex: Int,
        isHeader: Bool
    ) -> NSTextTableBlock {
        let block = NSTextTableBlock(
            table: table,
            startingRow: rowIndex,
            rowSpan: 1,
            startingColumn: columnIndex,
            columnSpan: 1
        )
        block.verticalAlignment = .middleAlignment
        block.setWidth(isHeader ? 8 : 7, type: .absoluteValueType, for: .padding)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(theme.tableBorderColor)
        if isHeader {
            block.backgroundColor = theme.tableHeaderBackgroundColor
        } else if rowIndex.isMultiple(of: 2) {
            block.backgroundColor = theme.tableAlternateRowBackgroundColor
        } else {
            block.backgroundColor = theme.tableRowBackgroundColor
        }
        return block
    }

    private func tableCellAttributes(
        tableBlock: NSTextTableBlock,
        row: CMUXMarkdownTableRow
    ) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.textBlocks = [tableBlock]
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 0
        paragraph.alignment = .left

        let font: NSFont = row.isHeader
            ? NSFont.systemFont(ofSize: theme.baseFont.pointSize, weight: .semibold)
            : theme.baseFont
        let color = row.isHeader ? theme.foregroundColor : theme.foregroundColor.withAlphaComponent(0.96)

        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    private func renderedText(for block: CMUXMarkdownBlock) -> (text: String, separator: String) {
        switch block.kind {
        case .paragraph, .heading:
            return (block.text, "\n")
        case .unorderedListItem(let depth, let taskState):
            let indent = String(repeating: "  ", count: max(0, depth))
            let checkbox: String
            switch taskState {
            case .checked:
                checkbox = "[x] "
            case .unchecked:
                checkbox = "[ ] "
            case nil:
                checkbox = ""
            }
            return ("\(indent)- \(checkbox)\(block.text)", "\n")
        case .orderedListItem(let depth, let number):
            let indent = String(repeating: "  ", count: max(0, depth))
            return ("\(indent)\(number). \(block.text)", "\n")
        case .blockQuote(let depth):
            let prefix = String(repeating: "> ", count: max(1, depth))
            return (block.text.split(separator: "\n", omittingEmptySubsequences: false).map { "\(prefix)\($0)" }.joined(separator: "\n"), "\n")
        case .codeBlock:
            return (block.text, "\n")
        case .table:
            return (block.text, "\n")
        case .thematicBreak:
            return ("------------------------------", "\n")
        }
    }

    private func inlineTextOffset(for kind: CMUXMarkdownBlockKind) -> Int {
        switch kind {
        case .unorderedListItem(let depth, let taskState):
            let indentLength = max(0, depth) * 2
            let checkboxLength: Int
            switch taskState {
            case .checked, .unchecked:
                checkboxLength = 4
            case nil:
                checkboxLength = 0
            }
            return indentLength + 2 + checkboxLength
        case .orderedListItem(let depth, let number):
            return max(0, depth) * 2 + "\(number). ".utf16.count
        case .paragraph, .heading, .blockQuote, .codeBlock, .table, .thematicBreak:
            return 0
        }
    }

    private func attributes(for kind: CMUXMarkdownBlockKind) -> [NSAttributedString.Key: Any] {
        let font: NSFont
        let color: NSColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3

        switch kind {
        case .heading(let level):
            let size = theme.baseFont.pointSize * headingScale(level: level)
            font = NSFont.systemFont(ofSize: size, weight: .bold)
            color = theme.foregroundColor
            paragraph.paragraphSpacing = level == 1 ? 22 : CGFloat(max(10, 18 - level))
        case .codeBlock:
            font = theme.monospacedFont
            color = theme.codeColor
            paragraph.paragraphSpacing = 8
        case .table:
            font = theme.monospacedFont
            color = theme.foregroundColor
            paragraph.lineSpacing = 2
            paragraph.paragraphSpacing = 14
        case .blockQuote:
            font = theme.baseFont
            color = theme.mutedColor
            paragraph.paragraphSpacing = 8
        case .thematicBreak:
            font = theme.monospacedFont
            color = theme.mutedColor
            paragraph.paragraphSpacing = 8
        case .unorderedListItem(let depth, _), .orderedListItem(let depth, _):
            font = theme.baseFont
            color = theme.foregroundColor
            let indent = CGFloat(max(0, depth)) * 18
            paragraph.firstLineHeadIndent = indent
            paragraph.headIndent = indent + 18
            paragraph.paragraphSpacing = 5
        case .paragraph:
            font = theme.baseFont
            color = theme.foregroundColor
            paragraph.paragraphSpacing = 14
        }

        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    }

    private func apply(
        span: CMUXMarkdownInlineSpan,
        blockKind: CMUXMarkdownBlockKind,
        blockStart: Int,
        to output: NSMutableAttributedString
    ) {
        let range = NSRange(location: blockStart + span.range.location, length: span.range.length)
        guard range.location >= 0, range.upperBound <= output.length, range.length > 0 else { return }

        if span.styles.contains(.code) {
            output.addAttributes(
                [
                    .font: theme.monospacedFont,
                    .foregroundColor: theme.codeColor,
                ],
                range: range
            )
            return
        }

        var traits: NSFontTraitMask = []
        if span.styles.contains(.strong) {
            traits.insert(.boldFontMask)
        }
        if span.styles.contains(.emphasis) {
            traits.insert(.italicFontMask)
        }
        let baseFont = blockKind == .table ? theme.monospacedFont : theme.baseFont
        if !traits.isEmpty,
           let font = NSFontManager.shared.convert(baseFont, toHaveTrait: traits) as NSFont? {
            output.addAttribute(.font, value: font, range: range)
        }
        if span.styles.contains(.link) {
            output.addAttribute(.foregroundColor, value: theme.linkColor, range: range)
            output.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            if let destination = span.linkDestination {
                output.addAttribute(.link, value: destination, range: range)
            }
        }
        if span.styles.contains(.strikethrough) {
            output.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
    }

    private func highlightCode(
        _ code: String,
        language: String?,
        blockStart: Int,
        in output: NSMutableAttributedString
    ) {
        let language = language?.lowercased()
        if language == nil || language == "swift" {
            highlightSwiftCode(code, blockStart: blockStart, in: output)
        }
    }

    private func highlightSwiftCode(
        _ code: String,
        blockStart: Int,
        in output: NSMutableAttributedString
    ) {
        let nsCode = code as NSString
        let keywords: Set<String> = [
            "actor", "async", "await", "case", "catch", "class", "default", "else", "enum",
            "extension", "false", "final", "for", "func", "if", "import", "in", "internal",
            "let", "nil", "private", "protocol", "public", "return", "self", "static",
            "struct", "switch", "throws", "true", "try", "var", "while",
        ]

        func add(_ color: NSColor, range: NSRange) {
            let target = NSRange(location: blockStart + range.location, length: range.length)
            guard target.location >= 0, target.upperBound <= output.length else { return }
            output.addAttribute(.foregroundColor, value: color, range: target)
        }

        var location = 0
        while location < nsCode.length {
            let lineRange = nsCode.lineRange(for: NSRange(location: location, length: 0))
            let line = nsCode.substring(with: lineRange)
            let lineNSString = line as NSString

            if let commentRange = line.range(of: "//") {
                let start = line.distance(from: line.startIndex, to: commentRange.lowerBound)
                add(theme.codeBlockCommentColor, range: NSRange(location: lineRange.location + start, length: lineRange.length - start))
            }

            var cursor = 0
            var inString = false
            var stringStart = 0
            while cursor < lineNSString.length {
                let scalar = lineNSString.character(at: cursor)
                if scalar == 34 {
                    if inString {
                        add(theme.codeBlockStringColor, range: NSRange(location: lineRange.location + stringStart, length: cursor - stringStart + 1))
                        inString = false
                    } else {
                        stringStart = cursor
                        inString = true
                    }
                }
                cursor += 1
            }

            let matches = swiftIdentifierMatches(in: line)
            for match in matches {
                let token = lineNSString.substring(with: match)
                if keywords.contains(token) {
                    add(theme.codeBlockKeywordColor, range: NSRange(location: lineRange.location + match.location, length: match.length))
                } else if token.first?.isUppercase == true {
                    add(theme.codeBlockTypeColor, range: NSRange(location: lineRange.location + match.location, length: match.length))
                }
            }

            location = lineRange.upperBound
        }
    }

    private func swiftIdentifierMatches(in line: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let scalars = Array(line.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard isSwiftIdentifierStart(scalar) else {
                index += 1
                continue
            }

            let start = index
            index += 1
            while index < scalars.count {
                let next = scalars[index]
                if isSwiftIdentifierContinuation(next) {
                    index += 1
                } else {
                    break
                }
            }
            ranges.append(NSRange(location: start, length: index - start))
        }
        return ranges
    }

    private func isSwiftIdentifierStart(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" ||
            (65...90).contains(scalar.value) ||
            (97...122).contains(scalar.value)
    }

    private func isSwiftIdentifierContinuation(_ scalar: Unicode.Scalar) -> Bool {
        isSwiftIdentifierStart(scalar) || (48...57).contains(scalar.value)
    }

    private func headingScale(level: Int) -> CGFloat {
        switch level {
        case 1:
            return 1.85
        case 2:
            return 1.55
        case 3:
            return 1.30
        case 4:
            return 1.15
        default:
            return 1.0
        }
    }
}
#endif
