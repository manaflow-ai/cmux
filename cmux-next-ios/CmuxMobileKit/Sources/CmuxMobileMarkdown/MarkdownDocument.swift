import Foundation

/// A markdown document split into top-level blocks. Transcript prose renders
/// block by block natively (SPEC 6.3); inline syntax inside a block goes
/// through `AttributedString(markdown:)`. Parsing is line based and cheap, so
/// the streaming tail block can re-parse every tick.
public struct MarkdownDocument: Hashable, Sendable {
    public var blocks: [MarkdownBlock]

    public init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    public init(parsing text: String) {
        self.blocks = MarkdownParser(text: text).parse()
    }

    /// True when a block needs the web renderer (display math, or a paragraph with inline `$...$`).
    public var needsWebRenderer: Bool {
        blocks.contains { $0.kind.needsWebRenderer }
    }
}

public struct MarkdownBlock: Hashable, Sendable, Identifiable {
    /// Stable for a given position: the streaming tail keeps its id while it grows.
    public var id: Int
    public var kind: Kind

    public init(id: Int, kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public enum Kind: Hashable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case list(MarkdownList)
        case code(language: String?, code: String, isClosed: Bool)
        case table(MarkdownTable)
        case quote(String)
        case math(String)
        case rule

        var needsWebRenderer: Bool {
            switch self {
            case .math: true
            case .paragraph(let text): MarkdownInlineMath.contains(text)
            default: false
            }
        }
    }
}

public struct MarkdownList: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public var text: String
        public var depth: Int
        public var ordinal: Int?
        public var checked: Bool?

        public init(text: String, depth: Int, ordinal: Int?, checked: Bool?) {
            self.text = text
            self.depth = depth
            self.ordinal = ordinal
            self.checked = checked
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }
}

public struct MarkdownTable: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable { case leading, center, trailing }

    public var header: [String]
    public var alignments: [Alignment]
    public var rows: [[String]]

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }

    public var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }

    /// Plain text with tab-separated cells (Copy).
    public var plainText: String {
        ([header] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }
}

/// Detects `$...$` / `\(...\)` inline math without tripping on prices ("$5 and $6").
struct MarkdownInlineMath {
    static func contains(_ text: String) -> Bool {
        if text.contains("\\(") && text.contains("\\)") { return true }
        guard text.contains("$") else { return false }
        let chars = Array(text)
        var index = 0
        while index < chars.count {
            defer { index += 1 }
            guard chars[index] == "$" else { continue }
            if index > 0, chars[index - 1] == "\\" || chars[index - 1] == "$" || chars[index - 1].isLetter || chars[index - 1].isNumber { continue }
            guard index + 1 < chars.count, !chars[index + 1].isWhitespace, chars[index + 1] != "$" else { continue }
            var end = index + 1
            while end < chars.count, chars[end] != "$", chars[end] != "\n" { end += 1 }
            guard end < chars.count, chars[end] == "$", !chars[end - 1].isWhitespace else { continue }
            if end + 1 < chars.count, chars[end + 1].isLetter || chars[end + 1].isNumber { continue }
            return true
        }
        return false
    }
}

struct MarkdownParser {
    let lines: [Substring]

    init(text: String) {
        self.lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    func parse() -> [MarkdownBlock] {
        parseWithStarts().blocks
    }

    /// The blocks and the line each one starts on.
    func parseWithStarts() -> (blocks: [MarkdownBlock], starts: [Int]) {
        var blocks: [MarkdownBlock] = []
        var starts: [Int] = []
        var index = 0
        var blockStart = 0
        func append(_ kind: MarkdownBlock.Kind) {
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind))
            starts.append(blockStart)
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                index += 1
                continue
            }
            blockStart = index
            // Fenced code.
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [Substring] = []
                index += 1
                var closed = false
                while index < lines.count {
                    if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                        closed = true
                        index += 1
                        break
                    }
                    body.append(lines[index])
                    index += 1
                }
                append(.code(language: language.isEmpty ? nil : language, code: body.joined(separator: "\n"), isClosed: closed))
                continue
            }
            // Display math.
            if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
                let close = trimmed.hasPrefix("$$") ? "$$" : "\\]"
                var tex = String(trimmed.dropFirst(2))
                if tex.hasSuffix(close), tex.count >= 2 {
                    tex.removeLast(2)
                    append(.math(tex.trimmingCharacters(in: .whitespaces)))
                    index += 1
                    continue
                }
                var body: [String] = tex.isEmpty ? [] : [tex]
                var closed = false
                index += 1
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    index += 1
                    if current.hasSuffix(close) {
                        let rest = String(current.dropLast(2))
                        if !rest.isEmpty { body.append(rest) }
                        closed = true
                        break
                    }
                    body.append(current)
                }
                // A display block still streaming in shows as TeX source until it closes.
                append(closed ? .math(body.joined(separator: "\n")) : .code(language: "tex", code: body.joined(separator: "\n"), isClosed: false))
                continue
            }
            // Headings.
            if let heading = Self.heading(trimmed) {
                append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }
            // Rule.
            if Self.isRule(trimmed) {
                append(.rule)
                index += 1
                continue
            }
            // Table: a pipe row followed by a delimiter row.
            if trimmed.contains("|"), index + 1 < lines.count, Self.isTableDelimiter(lines[index + 1]) {
                let header = Self.cells(trimmed)
                let alignments = Self.cells(lines[index + 1].trimmingCharacters(in: .whitespaces)).map(Self.alignment)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(Self.cells(row))
                    index += 1
                }
                append(.table(MarkdownTable(header: header, alignments: alignments, rows: rows)))
                continue
            }
            // Blockquote.
            if trimmed.hasPrefix(">") {
                var body: [String] = []
                while index < lines.count {
                    let current = lines[index].trimmingCharacters(in: .whitespaces)
                    guard current.hasPrefix(">") else { break }
                    body.append(String(current.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                append(.quote(body.joined(separator: "\n")))
                continue
            }
            // Lists.
            if Self.listItem(line) != nil {
                var items: [MarkdownList.Item] = []
                while index < lines.count {
                    let current = lines[index]
                    if let item = Self.listItem(current) {
                        items.append(item)
                        index += 1
                    } else if !current.trimmingCharacters(in: .whitespaces).isEmpty,
                              current.first == " " || current.first == "\t", !items.isEmpty {
                        // Continuation line of the previous item.
                        items[items.count - 1].text += " " + current.trimmingCharacters(in: .whitespaces)
                        index += 1
                    } else {
                        break
                    }
                }
                append(.list(MarkdownList(items: items)))
                continue
            }
            // Paragraph: until a blank line or another block starts.
            var body: [String] = []
            while index < lines.count {
                let current = lines[index]
                let currentTrimmed = current.trimmingCharacters(in: .whitespaces)
                if currentTrimmed.isEmpty { break }
                if !body.isEmpty, Self.startsBlock(currentTrimmed, raw: current) { break }
                body.append(currentTrimmed)
                index += 1
            }
            append(.paragraph(body.joined(separator: "\n")))
        }
        return (blocks, starts)
    }

    private static func startsBlock(_ trimmed: String, raw: Substring) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") || trimmed.hasPrefix("$$") || trimmed.hasPrefix(">")
            || heading(trimmed) != nil || isRule(trimmed) || listItem(raw) != nil
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func isTableDelimiter(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") || trimmed.hasPrefix(":") else { return false }
        return trimmed.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ row: String) -> [String] {
        var row = row
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") { row.removeLast() }
        // Split on pipes that are not escaped and not inside inline code.
        var cells: [String] = []
        var current = ""
        var inCode = false
        var previous: Character?
        for character in row {
            if character == "`" { inCode.toggle() }
            if character == "|", !inCode, previous != "\\" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    static func alignment(_ cell: String) -> MarkdownTable.Alignment {
        switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
        case (true, true): .center
        case (false, true): .trailing
        default: .leading
        }
    }

    static func listItem(_ raw: Substring) -> MarkdownList.Item? {
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let line = raw.dropFirst(raw.prefix { $0 == " " || $0 == "\t" }.count)
        var ordinal: Int?
        var rest: Substring
        if let marker = line.first, "-*+".contains(marker), line.dropFirst().first == " " {
            rest = line.dropFirst(2)
        } else {
            let digits = line.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count < 4 else { return nil }
            let after = line.dropFirst(digits.count)
            guard let punctuation = after.first, punctuation == "." || punctuation == ")", after.dropFirst().first == " " else { return nil }
            ordinal = Int(digits)
            rest = after.dropFirst(2)
        }
        var checked: Bool?
        if rest.hasPrefix("[ ] ") {
            checked = false
            rest = rest.dropFirst(4)
        } else if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") {
            checked = true
            rest = rest.dropFirst(4)
        }
        return MarkdownList.Item(text: String(rest), depth: indent / 2, ordinal: ordinal, checked: checked)
    }
}
