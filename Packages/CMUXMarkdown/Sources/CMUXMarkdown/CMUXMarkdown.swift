import Foundation

public struct CMUXMarkdownDocument: Equatable, Sendable {
    public var blocks: [CMUXMarkdownBlock]

    public init(blocks: [CMUXMarkdownBlock]) {
        self.blocks = blocks
    }
}

public enum CMUXMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, inlines: [CMUXMarkdownInline])
    case paragraph([CMUXMarkdownInline])
    case unorderedList(items: [[CMUXMarkdownInline]])
    case orderedList(start: Int, items: [[CMUXMarkdownInline]])
    case codeBlock(info: String?, code: String)
    case blockQuote([CMUXMarkdownBlock])
    case table(header: [[CMUXMarkdownInline]], rows: [[[CMUXMarkdownInline]]])
    case thematicBreak
}

public enum CMUXMarkdownInline: Equatable, Sendable {
    case text(String)
    case softBreak
    case code(String)
    case strong([CMUXMarkdownInline])
    case emphasis([CMUXMarkdownInline])
    case link(label: [CMUXMarkdownInline], destination: String)
}

public enum CMUXMarkdown {
    public static func parse(_ markdown: String) -> CMUXMarkdownDocument {
        CMUXMarkdownParser().parse(markdown)
    }

    public static func parseInlines(_ markdown: String) -> [CMUXMarkdownInline] {
        CMUXMarkdownInlineParser.parse(markdown)
    }

    public static func attributedString(
        fromMarkdown markdown: String,
        mode: CMUXMarkdownAttributedMode = .inlineOnlyPreservingWhitespace
    ) -> AttributedString {
        switch mode {
        case .inlineOnlyPreservingWhitespace:
            return CMUXMarkdownAttributedRenderer.attributedString(from: parseInlines(markdown))
        case .fullDocumentPlain:
            return CMUXMarkdownAttributedRenderer.attributedString(from: parse(markdown))
        }
    }

    public static func plainText(from document: CMUXMarkdownDocument) -> String {
        CMUXMarkdownPlainTextRenderer.render(document)
    }
}

public enum CMUXMarkdownAttributedMode: Sendable {
    case inlineOnlyPreservingWhitespace
    case fullDocumentPlain
}

public struct CMUXMarkdownParser: Sendable {
    public init() {}

    public func parse(_ markdown: String) -> CMUXMarkdownDocument {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)

        var index = 0
        let blocks = parseBlocks(lines: lines, index: &index)
        return CMUXMarkdownDocument(blocks: blocks)
    }

    private func parseBlocks<Line: StringProtocol>(lines: [Line], index: inout Int) -> [CMUXMarkdownBlock] {
        var blocks: [CMUXMarkdownBlock] = []

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                index += 1
                continue
            }

            if let fence = parseFenceStart(line) {
                blocks.append(parseCodeBlock(lines: lines, index: &index, fence: fence))
                continue
            }

            if let heading = parseHeading(line) {
                blocks.append(.heading(level: heading.level, inlines: CMUXMarkdownInlineParser.parse(heading.text)))
                index += 1
                continue
            }

            if isThematicBreak(line) {
                blocks.append(.thematicBreak)
                index += 1
                continue
            }

            if isTableStart(lines: lines, index: index) {
                blocks.append(parseTable(lines: lines, index: &index))
                continue
            }

            if isBlockQuote(line) {
                blocks.append(parseBlockQuote(lines: lines, index: &index))
                continue
            }

            if let listMarker = parseListMarker(line) {
                blocks.append(parseList(lines: lines, index: &index, marker: listMarker))
                continue
            }

            blocks.append(parseParagraph(lines: lines, index: &index))
        }

        return blocks
    }

    private func parseCodeBlock<Line: StringProtocol>(
        lines: [Line],
        index: inout Int,
        fence: FenceStart
    ) -> CMUXMarkdownBlock {
        index += 1
        var body: [String] = []

        while index < lines.count {
            let line = lines[index]
            if matchesFenceEnd(line, fence: fence) {
                index += 1
                break
            }
            body.append(String(line))
            index += 1
        }

        return .codeBlock(info: fence.info.isEmpty ? nil : fence.info, code: body.joined(separator: "\n"))
    }

    private func parseTable<Line: StringProtocol>(lines: [Line], index: inout Int) -> CMUXMarkdownBlock {
        let header = splitTableRow(lines[index]).map(CMUXMarkdownInlineParser.parse)
        index += 2

        var rows: [[[CMUXMarkdownInline]]] = []
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty || !line.contains("|") {
                break
            }
            rows.append(splitTableRow(line).map(CMUXMarkdownInlineParser.parse))
            index += 1
        }

        return .table(header: header, rows: rows)
    }

    private func parseBlockQuote<Line: StringProtocol>(lines: [Line], index: inout Int) -> CMUXMarkdownBlock {
        var quoted: [String] = []
        while index < lines.count, isBlockQuote(lines[index]) {
            quoted.append(stripBlockQuoteMarker(lines[index]))
            index += 1
        }
        var quotedIndex = 0
        return .blockQuote(parseBlocks(lines: quoted, index: &quotedIndex))
    }

    private func parseList<Line: StringProtocol>(
        lines: [Line],
        index: inout Int,
        marker: ListMarker
    ) -> CMUXMarkdownBlock {
        var items: [[CMUXMarkdownInline]] = []
        var orderedStart = marker.start ?? 1
        var isFirst = true

        while index < lines.count {
            guard let current = parseListMarker(lines[index]),
                  current.isOrdered == marker.isOrdered
            else { break }
            if isFirst {
                orderedStart = current.start ?? orderedStart
                isFirst = false
            }

            var itemLines = [current.content]
            index += 1

            while index < lines.count {
                let next = lines[index]
                if next.trimmingCharacters(in: .whitespaces).isEmpty {
                    break
                }
                if parseListMarker(next) != nil || isBlockStart(next) {
                    break
                }
                if countLeadingSpaces(next) >= 2 {
                    itemLines.append(next.trimmingCharacters(in: .whitespaces))
                    index += 1
                } else {
                    break
                }
            }

            items.append(CMUXMarkdownInlineParser.parse(itemLines.joined(separator: "\n")))
        }

        return marker.isOrdered ? .orderedList(start: orderedStart, items: items) : .unorderedList(items: items)
    }

    private func parseParagraph<Line: StringProtocol>(lines: [Line], index: inout Int) -> CMUXMarkdownBlock {
        var paragraphLines: [String] = []

        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                break
            }
            if !paragraphLines.isEmpty, isBlockStart(line) {
                break
            }
            paragraphLines.append(line.trimmingCharacters(in: .whitespaces))
            index += 1
        }

        return .paragraph(CMUXMarkdownInlineParser.parse(paragraphLines.joined(separator: "\n")))
    }

    private func isBlockStart<Line: StringProtocol>(_ line: Line) -> Bool {
        parseFenceStart(line) != nil ||
            parseHeading(line) != nil ||
            isThematicBreak(line) ||
            isBlockQuote(line) ||
            parseListMarker(line) != nil
    }
}

private struct FenceStart {
    let marker: Character
    let count: Int
    let info: String
}

private struct ListMarker: Equatable {
    let isOrdered: Bool
    let start: Int?
    let content: String
}

private func parseFenceStart<Line: StringProtocol>(_ line: Line) -> FenceStart? {
    let trimmed = line.drop { $0 == " " || $0 == "\t" }
    guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
    var count = 0
    var cursor = trimmed.startIndex
    while cursor < trimmed.endIndex, trimmed[cursor] == first {
        count += 1
        cursor = trimmed.index(after: cursor)
    }
    guard count >= 3 else { return nil }
    let info = String(trimmed[cursor...]).trimmingCharacters(in: .whitespaces)
    return FenceStart(marker: first, count: count, info: info)
}

private func matchesFenceEnd<Line: StringProtocol>(_ line: Line, fence: FenceStart) -> Bool {
    let trimmed = line.drop { $0 == " " || $0 == "\t" }
    var count = 0
    var cursor = trimmed.startIndex
    while cursor < trimmed.endIndex, trimmed[cursor] == fence.marker {
        count += 1
        cursor = trimmed.index(after: cursor)
    }
    guard count >= fence.count else { return false }
    return trimmed[cursor...].allSatisfy { $0 == " " || $0 == "\t" }
}

private func parseHeading<Line: StringProtocol>(_ line: Line) -> (level: Int, text: String)? {
    guard countLeadingSpaces(line) <= 3 else { return nil }
    let trimmed = line.drop { $0 == " " }
    var cursor = trimmed.startIndex
    var level = 0
    while cursor < trimmed.endIndex, trimmed[cursor] == "#", level < 6 {
        level += 1
        cursor = trimmed.index(after: cursor)
    }
    guard level > 0 else { return nil }
    guard cursor == trimmed.endIndex || trimmed[cursor] == " " || trimmed[cursor] == "\t" else { return nil }
    let raw = String(trimmed[cursor...]).trimmingCharacters(in: .whitespaces)
    let text = trimClosingHeadingMarkers(raw)
    return (level, text)
}

private func trimClosingHeadingMarkers(_ raw: String) -> String {
    var characters = Array(raw)
    while characters.last == " " || characters.last == "\t" {
        characters.removeLast()
    }
    var cursor = characters.count
    while cursor > 0, characters[cursor - 1] == "#" {
        cursor -= 1
    }
    guard cursor < characters.count else { return String(characters) }
    guard cursor > 0, characters[cursor - 1] == " " || characters[cursor - 1] == "\t" else {
        return String(characters)
    }
    while cursor > 0, characters[cursor - 1] == " " || characters[cursor - 1] == "\t" {
        cursor -= 1
    }
    return String(characters[..<cursor])
}

private func isThematicBreak<Line: StringProtocol>(_ line: Line) -> Bool {
    let chars = line.filter { $0 != " " && $0 != "\t" }
    guard chars.count >= 3, let first = chars.first else { return false }
    guard first == "-" || first == "*" || first == "_" else { return false }
    return chars.allSatisfy { $0 == first }
}

private func isTableStart<Line: StringProtocol>(lines: [Line], index: Int) -> Bool {
    guard index + 1 < lines.count, lines[index].contains("|") else { return false }
    let cells = splitTableRow(lines[index + 1])
    guard !cells.isEmpty else { return false }
    return cells.allSatisfy(isTableSeparatorCell)
}

private func splitTableRow<Line: StringProtocol>(_ line: Line) -> [String] {
    var row = line.trimmingCharacters(in: .whitespaces)
    if row.first == "|" { row.removeFirst() }
    if row.last == "|" { row.removeLast() }
    return row.split(separator: "|", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .whitespaces) }
}

private func isTableSeparatorCell(_ cell: String) -> Bool {
    var trimmed = cell.trimmingCharacters(in: .whitespaces)
    if trimmed.first == ":" { trimmed.removeFirst() }
    if trimmed.last == ":" { trimmed.removeLast() }
    return trimmed.count >= 3 && trimmed.allSatisfy { $0 == "-" }
}

private func isBlockQuote<Line: StringProtocol>(_ line: Line) -> Bool {
    let trimmed = line.drop { $0 == " " || $0 == "\t" }
    return trimmed.first == ">"
}

private func stripBlockQuoteMarker<Line: StringProtocol>(_ line: Line) -> String {
    let trimmed = line.drop { $0 == " " || $0 == "\t" }
    guard trimmed.first == ">" else { return String(line) }
    var cursor = trimmed.index(after: trimmed.startIndex)
    if cursor < trimmed.endIndex, trimmed[cursor] == " " {
        cursor = trimmed.index(after: cursor)
    }
    return String(trimmed[cursor...])
}

private func parseListMarker<Line: StringProtocol>(_ line: Line) -> ListMarker? {
    guard countLeadingSpaces(line) <= 3 else { return nil }
    let trimmed = line.drop { $0 == " " || $0 == "\t" }
    guard !trimmed.isEmpty else { return nil }

    if let first = trimmed.first, first == "-" || first == "*" || first == "+" {
        let markerEnd = trimmed.index(after: trimmed.startIndex)
        guard markerEnd < trimmed.endIndex, trimmed[markerEnd] == " " || trimmed[markerEnd] == "\t" else { return nil }
        let content = String(trimmed[trimmed.index(after: markerEnd)...])
        return ListMarker(isOrdered: false, start: nil, content: content)
    }

    var cursor = trimmed.startIndex
    var value = 0
    var digitCount = 0
    while cursor < trimmed.endIndex, let digit = trimmed[cursor].wholeNumberValue {
        value = value * 10 + digit
        digitCount += 1
        cursor = trimmed.index(after: cursor)
    }
    guard digitCount > 0, cursor < trimmed.endIndex else { return nil }
    guard trimmed[cursor] == "." || trimmed[cursor] == ")" else { return nil }
    let separator = cursor
    cursor = trimmed.index(after: cursor)
    guard cursor < trimmed.endIndex, trimmed[cursor] == " " || trimmed[cursor] == "\t" else { return nil }
    let content = String(trimmed[trimmed.index(after: cursor)...])
    _ = separator
    return ListMarker(isOrdered: true, start: value, content: content)
}

private func countLeadingSpaces<Line: StringProtocol>(_ line: Line) -> Int {
    var count = 0
    for character in line {
        if character == " " {
            count += 1
        } else if character == "\t" {
            count += 4
        } else {
            break
        }
    }
    return count
}

enum CMUXMarkdownInlineParser {
    static func parse(_ source: String) -> [CMUXMarkdownInline] {
        guard !source.isEmpty else { return [] }
        guard containsInlineSyntax(source) else { return [.text(source)] }
        let bytes = Array(source.utf8)
        var output: [CMUXMarkdownInline] = []
        var buffer: [UInt8] = []
        var index = 0

        func flushBuffer() {
            guard !buffer.isEmpty else { return }
            output.append(.text(String(decoding: buffer, as: UTF8.self)))
            buffer.removeAll(keepingCapacity: true)
        }

        while index < bytes.count {
            let byte = bytes[index]

            if byte == asciiBackslash, index + 1 < bytes.count {
                buffer.append(bytes[index + 1])
                index += 2
                continue
            }

            if byte == asciiNewline {
                flushBuffer()
                output.append(.softBreak)
                index += 1
                continue
            }

            if byte == asciiBacktick, let end = findNext(asciiBacktick, in: bytes, from: index + 1) {
                flushBuffer()
                output.append(.code(String(decoding: bytes[(index + 1)..<end], as: UTF8.self)))
                index = end + 1
                continue
            }

            if byte == asciiAsterisk,
               index + 1 < bytes.count,
               bytes[index + 1] == asciiAsterisk,
               let end = findNextPair(asciiAsterisk, asciiAsterisk, in: bytes, from: index + 2)
            {
                flushBuffer()
                output.append(.strong(parse(String(decoding: bytes[(index + 2)..<end], as: UTF8.self))))
                index = end + 2
                continue
            }

            if byte == asciiAsterisk,
               let end = findNext(asciiAsterisk, in: bytes, from: index + 1),
               end > index + 1
            {
                flushBuffer()
                output.append(.emphasis(parse(String(decoding: bytes[(index + 1)..<end], as: UTF8.self))))
                index = end + 1
                continue
            }

            if byte == asciiOpenBracket,
               let closeLabel = findNext(asciiCloseBracket, in: bytes, from: index + 1),
               closeLabel + 1 < bytes.count,
               bytes[closeLabel + 1] == asciiOpenParen,
               let closeDestination = findNext(asciiCloseParen, in: bytes, from: closeLabel + 2)
            {
                let destination = String(decoding: bytes[(closeLabel + 2)..<closeDestination], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !destination.isEmpty {
                    flushBuffer()
                    output.append(.link(
                        label: parse(String(decoding: bytes[(index + 1)..<closeLabel], as: UTF8.self)),
                        destination: destination
                    ))
                    index = closeDestination + 1
                    continue
                }
            }

            buffer.append(byte)
            index += 1
        }

        flushBuffer()
        return coalesceText(output)
    }

    private static let asciiBackslash = UInt8(ascii: "\\")
    private static let asciiNewline = UInt8(ascii: "\n")
    private static let asciiBacktick = UInt8(ascii: "`")
    private static let asciiAsterisk = UInt8(ascii: "*")
    private static let asciiOpenBracket = UInt8(ascii: "[")
    private static let asciiCloseBracket = UInt8(ascii: "]")
    private static let asciiOpenParen = UInt8(ascii: "(")
    private static let asciiCloseParen = UInt8(ascii: ")")

    private static func containsInlineSyntax(_ source: String) -> Bool {
        for byte in source.utf8 {
            switch byte {
            case asciiBackslash, asciiNewline, asciiBacktick, asciiAsterisk, asciiOpenBracket:
                return true
            default:
                continue
            }
        }
        return false
    }

    private static func findNext(_ needle: UInt8, in bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        var index = start
        while index < bytes.count {
            if bytes[index] == needle {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func findNextPair(_ first: UInt8, _ second: UInt8, in bytes: [UInt8], from start: Int) -> Int? {
        guard start + 1 < bytes.count else { return nil }
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == first && bytes[index + 1] == second {
                return index
            }
            index += 1
        }
        return nil
    }

    private static func coalesceText(_ inlines: [CMUXMarkdownInline]) -> [CMUXMarkdownInline] {
        var output: [CMUXMarkdownInline] = []
        for inline in inlines {
            if case let .text(text) = inline,
               case let .text(previous) = output.last
            {
                output.removeLast()
                output.append(.text(previous + text))
            } else {
                output.append(inline)
            }
        }
        return output
    }
}

public enum CMUXMarkdownAttributedRenderer {
    public static func attributedString(from document: CMUXMarkdownDocument) -> AttributedString {
        var result = AttributedString()
        for (index, block) in document.blocks.enumerated() {
            if index > 0 {
                result += AttributedString("\n\n")
            }
            result += attributedString(from: block)
        }
        return result
    }

    public static func attributedString(from block: CMUXMarkdownBlock) -> AttributedString {
        switch block {
        case let .heading(_, inlines), let .paragraph(inlines):
            return attributedString(from: inlines)
        case let .unorderedList(items):
            return joinedList(items: items) { _ in "• " }
        case let .orderedList(start, items):
            return joinedList(items: items) { "\($0 + start). " }
        case let .codeBlock(_, code):
            var output = AttributedString(code)
            output.inlinePresentationIntent = .code
            return output
        case let .blockQuote(blocks):
            return attributedString(from: CMUXMarkdownDocument(blocks: blocks))
        case let .table(header, rows):
            var output = joinedCells(header)
            for row in rows {
                output += AttributedString("\n")
                output += joinedCells(row)
            }
            return output
        case .thematicBreak:
            return AttributedString("---")
        }
    }

    public static func attributedString(from inlines: [CMUXMarkdownInline]) -> AttributedString {
        var output = AttributedString()
        for inline in inlines {
            output += attributedString(from: inline)
        }
        return output
    }

    private static func attributedString(from inline: CMUXMarkdownInline) -> AttributedString {
        switch inline {
        case let .text(text):
            return AttributedString(text)
        case .softBreak:
            return AttributedString("\n")
        case let .code(code):
            var output = AttributedString(code)
            output.inlinePresentationIntent = .code
            return output
        case let .strong(inlines):
            var output = attributedString(from: inlines)
            output.inlinePresentationIntent = .stronglyEmphasized
            return output
        case let .emphasis(inlines):
            var output = attributedString(from: inlines)
            output.inlinePresentationIntent = .emphasized
            return output
        case let .link(label, destination):
            var output = attributedString(from: label)
            output.link = URL(string: destination)
            return output
        }
    }

    private static func joinedList(
        items: [[CMUXMarkdownInline]],
        prefix: (Int) -> String
    ) -> AttributedString {
        var output = AttributedString()
        for (index, item) in items.enumerated() {
            if index > 0 {
                output += AttributedString("\n")
            }
            output += AttributedString(prefix(index))
            output += attributedString(from: item)
        }
        return output
    }

    private static func joinedCells(_ cells: [[CMUXMarkdownInline]]) -> AttributedString {
        var output = AttributedString()
        for (index, cell) in cells.enumerated() {
            if index > 0 {
                output += AttributedString("    ")
            }
            output += attributedString(from: cell)
        }
        return output
    }
}

enum CMUXMarkdownPlainTextRenderer {
    static func render(_ document: CMUXMarkdownDocument) -> String {
        document.blocks.map(render).joined(separator: "\n\n")
    }

    private static func render(_ block: CMUXMarkdownBlock) -> String {
        switch block {
        case let .heading(_, inlines), let .paragraph(inlines):
            return render(inlines)
        case let .unorderedList(items):
            return items.map { "• " + render($0) }.joined(separator: "\n")
        case let .orderedList(start, items):
            return items.enumerated().map { "\($0.offset + start). " + render($0.element) }.joined(separator: "\n")
        case let .codeBlock(_, code):
            return code
        case let .blockQuote(blocks):
            return render(CMUXMarkdownDocument(blocks: blocks))
        case let .table(header, rows):
            return ([header] + rows).map { row in
                row.map(render).joined(separator: "\t")
            }.joined(separator: "\n")
        case .thematicBreak:
            return "---"
        }
    }

    private static func render(_ inlines: [CMUXMarkdownInline]) -> String {
        inlines.map(render).joined()
    }

    private static func render(_ inline: CMUXMarkdownInline) -> String {
        switch inline {
        case let .text(text), let .code(text):
            return text
        case .softBreak:
            return "\n"
        case let .strong(inlines), let .emphasis(inlines):
            return render(inlines)
        case let .link(label, _):
            return render(label)
        }
    }
}

#if canImport(SwiftUI) && canImport(AppKit)
import AppKit
import SwiftUI

public struct CMUXMarkdownTheme: Sendable {
    public var text: Color
    public var secondaryText: Color
    public var heading: Color
    public var link: Color
    public var codeForeground: Color
    public var codeBackground: Color
    public var quoteBorder: Color
    public var quoteText: Color
    public var tableBorder: Color
    public var tableAlternateRow: Color

    public init(
        text: Color,
        secondaryText: Color,
        heading: Color,
        link: Color,
        codeForeground: Color,
        codeBackground: Color,
        quoteBorder: Color,
        quoteText: Color,
        tableBorder: Color,
        tableAlternateRow: Color
    ) {
        self.text = text
        self.secondaryText = secondaryText
        self.heading = heading
        self.link = link
        self.codeForeground = codeForeground
        self.codeBackground = codeBackground
        self.quoteBorder = quoteBorder
        self.quoteText = quoteText
        self.tableBorder = tableBorder
        self.tableAlternateRow = tableAlternateRow
    }

    public static func cmux(colorScheme: ColorScheme) -> CMUXMarkdownTheme {
        let isDark = colorScheme == .dark
        return CMUXMarkdownTheme(
            text: isDark ? .white.opacity(0.9) : .primary,
            secondaryText: isDark ? .white.opacity(0.68) : .secondary,
            heading: isDark ? .white : .primary,
            link: .accentColor,
            codeForeground: isDark
                ? Color(red: 0.9, green: 0.9, blue: 0.9)
                : Color(red: 0.2, green: 0.2, blue: 0.2),
            codeBackground: isDark
                ? Color(nsColor: NSColor(white: 0.08, alpha: 1.0))
                : Color(nsColor: NSColor(white: 0.93, alpha: 1.0)),
            quoteBorder: isDark ? .white.opacity(0.2) : .gray.opacity(0.4),
            quoteText: isDark ? .white.opacity(0.62) : .secondary,
            tableBorder: isDark ? .white.opacity(0.15) : .gray.opacity(0.3),
            tableAlternateRow: isDark
                ? Color(nsColor: NSColor(white: 0.14, alpha: 1.0))
                : Color(nsColor: NSColor(white: 0.96, alpha: 1.0))
        )
    }
}

public struct CMUXMarkdownView: View {
    private let document: CMUXMarkdownDocument
    private let theme: CMUXMarkdownTheme

    public init(markdown: String, theme: CMUXMarkdownTheme) {
        self.document = CMUXMarkdown.parse(markdown)
        self.theme = theme
    }

    public init(document: CMUXMarkdownDocument, theme: CMUXMarkdownTheme) {
        self.document = document
        self.theme = theme
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: CMUXMarkdownBlock) -> some View {
        switch block {
        case let .heading(level, inlines):
            headingView(level: level, inlines: inlines)
        case let .paragraph(inlines):
            Text(CMUXMarkdownAttributedRenderer.attributedString(from: inlines))
                .font(.system(size: 14))
                .foregroundColor(theme.text)
                .lineSpacing(2)
                .padding(.top, 4)
                .padding(.bottom, 8)
        case let .unorderedList(items):
            listView(items: items, start: nil)
                .padding(.vertical, 4)
        case let .orderedList(start, items):
            listView(items: items, start: start)
                .padding(.vertical, 4)
        case let .codeBlock(info, code):
            codeBlockView(info: info, code: code)
                .padding(.vertical, 8)
        case let .blockQuote(blocks):
            blockQuoteView(blocks: blocks)
                .padding(.vertical, 8)
        case let .table(header, rows):
            tableView(header: header, rows: rows)
                .padding(.vertical, 8)
        case .thematicBreak:
            Divider()
                .padding(.vertical, 16)
        }
    }

    private func headingView(level: Int, inlines: [CMUXMarkdownInline]) -> some View {
        let size: CGFloat = switch level {
        case 1: 28
        case 2: 22
        case 3: 18
        case 4: 16
        case 5: 14
        default: 13
        }
        let weight: Font.Weight = level <= 2 ? .bold : (level <= 4 ? .semibold : .medium)
        let top: CGFloat = switch level {
        case 1: 24
        case 2: 20
        case 3: 16
        case 4: 12
        default: 8
        }
        let bottom: CGFloat = level <= 2 ? 12 : 6

        return VStack(alignment: .leading, spacing: level <= 2 ? 6 : 0) {
            Text(CMUXMarkdownAttributedRenderer.attributedString(from: inlines))
                .font(.system(size: size, weight: weight))
                .foregroundColor(level == 6 ? theme.secondaryText : theme.heading)
            if level <= 2 {
                Divider()
            }
        }
        .padding(.top, top)
        .padding(.bottom, bottom)
    }

    private func listView(items: [[CMUXMarkdownInline]], start: Int?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(start.map { "\(index + $0)." } ?? "•")
                        .font(.system(size: 14))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: start == nil ? 14 : 26, alignment: .trailing)
                    Text(CMUXMarkdownAttributedRenderer.attributedString(from: item))
                        .font(.system(size: 14))
                        .foregroundColor(theme.text)
                        .lineSpacing(2)
                }
            }
        }
    }

    private func codeBlockView(info: String?, code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 6) {
                if let info, !info.isEmpty {
                    Text(info)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(theme.codeForeground)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func blockQuoteView(blocks: [CMUXMarkdownBlock]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(theme.quoteBorder)
                .frame(width: 3)
            CMUXMarkdownView(document: CMUXMarkdownDocument(blocks: blocks), theme: theme)
                .foregroundColor(theme.quoteText)
                .padding(.leading, 12)
        }
    }

    private func tableView(header: [[CMUXMarkdownInline]], rows: [[[CMUXMarkdownInline]]]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                tableRow(header, isHeader: true, isAlternate: false)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    tableRow(row, isHeader: false, isAlternate: index.isMultiple(of: 2))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(theme.tableBorder, lineWidth: 1)
            }
        }
    }

    private func tableRow(
        _ cells: [[CMUXMarkdownInline]],
        isHeader: Bool,
        isAlternate: Bool
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(CMUXMarkdownAttributedRenderer.attributedString(from: cell))
                    .font(.system(size: 13, weight: isHeader ? .semibold : .regular))
                    .foregroundColor(isHeader ? theme.heading : theme.text)
                    .lineLimit(nil)
                    .frame(minWidth: 96, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(theme.tableBorder)
                            .frame(width: 1)
                    }
            }
        }
        .background(isHeader || !isAlternate ? Color.clear : theme.tableAlternateRow)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.tableBorder)
                .frame(height: 1)
        }
    }
}
#endif
