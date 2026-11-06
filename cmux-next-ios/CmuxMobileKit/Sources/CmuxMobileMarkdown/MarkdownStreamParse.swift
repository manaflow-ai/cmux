import Foundation

/// A growing markdown message (an agent's streamed answer) parsed by re-parsing only its
/// unfinished tail. `blocks` always equals `MarkdownDocument(parsing: source).blocks`.
///
/// The parser reads forward from a block's first line and decides where the block ends by
/// looking at most one line past it. Text only grows at its end, so every line but the last
/// is final, and a block whose following block starts before the last line can no longer
/// change. An update keeps those blocks and parses from the first block that could still
/// change: one or two blocks per streamed chunk instead of the whole message.
public struct MarkdownStreamParse: Sendable {
    public private(set) var source = ""
    /// The blocks of `source`.
    public private(set) var blocks: [MarkdownBlock] = []
    /// What a reader sees: `blocks`, or while streaming, the blocks of the source with the
    /// tail's unclosed inline markers hidden (`MarkdownStreamTail`).
    public private(set) var displayed: [MarkdownBlock] = []
    /// Lines the last update parsed (the whole message, or just its tail).
    public private(set) var lastParsedLines = 0
    private var isStreaming = false
    /// Each block's first line and that line's UTF-8 offset in `source`.
    private var starts: [Start] = []
    private var lastLine = 0

    private struct Start: Sendable {
        var line: Int
        var offset: Int
    }

    public init() {}

    public init(_ text: String, isStreaming: Bool = false) {
        update(text, isStreaming: isStreaming)
    }

    public mutating func update(_ text: String, isStreaming streaming: Bool) {
        if streaming == isStreaming, Self.sameText(text, source) { return }
        isStreaming = streaming
        let restart = restartPoint(for: text)
        let tail = restart.offset == 0 ? text : String(Substring(text.utf8[text.utf8.index(text.utf8.startIndex, offsetBy: restart.offset)...]))
        let parser = MarkdownParser(text: tail)
        let parsed = parser.parseWithStarts()
        let offsets = Self.lineOffsets(parser.lines)
        let kept = restart.keptBlocks
        blocks.removeSubrange(kept...)
        starts.removeSubrange(kept...)
        for (index, block) in parsed.blocks.enumerated() {
            blocks.append(MarkdownBlock(id: kept + index, kind: block.kind))
            let line = parsed.starts[index]
            starts.append(Start(line: restart.line + line, offset: restart.offset + offsets[line]))
        }
        lastLine = restart.line + max(parser.lines.count - 1, 0)
        lastParsedLines = parser.lines.count
        source = text
        if streaming, !blocks.isEmpty {
            // `MarkdownStreamTail` edits the text after the message's last blank line, which
            // can start before the block parsed again: show from the block holding it.
            let lastBlank = text.range(of: "\n\n", options: .backwards).map { text.utf8.distance(from: text.startIndex, to: $0.upperBound) } ?? 0
            var from = kept
            while from > 0, starts[from].offset > lastBlank { from -= 1 }
            let region = from == kept ? tail
                : String(Substring(text.utf8[text.utf8.index(text.utf8.startIndex, offsetBy: starts[from].offset)...]))
            let shown = MarkdownStreamTail(region).displayed
            let regionBlocks = shown == region && from == kept ? parsed.blocks : MarkdownParser(text: shown).parse()
            displayed = Array(blocks[..<from]) + regionBlocks.enumerated().map { MarkdownBlock(id: from + $0.offset, kind: $0.element.kind) }
        } else {
            displayed = blocks
        }
    }

    /// Where to parse from: the first block that `text` (the old source plus more) could
    /// change, or the start when `text` does not extend the old source.
    private func restartPoint(for text: String) -> (keptBlocks: Int, line: Int, offset: Int) {
        guard !blocks.isEmpty, Self.extends(text, source) else { return (0, 0, 0) }
        // Block k is final when block k + 1 starts on a complete line (before the last one).
        var kept = blocks.count - 1
        for index in 1..<max(starts.count, 1) where starts[index].line >= lastLine {
            kept = index - 1
            break
        }
        return (kept, starts[kept].line, starts[kept].offset)
    }

    private static func lineOffsets(_ lines: [Substring]) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            offsets.append(offset)
            offset += line.utf8.count + 1
        }
        return offsets
    }

    private static func sameText(_ a: String, _ b: String) -> Bool {
        a.utf8.count == b.utf8.count && a == b
    }

    /// `text` starts with `prefix` (byte-wise) and is longer.
    static func extends(_ text: String, _ prefix: String) -> Bool {
        let count = prefix.utf8.count
        guard text.utf8.count > count else { return false }
        let fast = text.utf8.withContiguousStorageIfAvailable { textBytes in
            prefix.utf8.withContiguousStorageIfAvailable { prefixBytes in
                count == 0 || memcmp(textBytes.baseAddress, prefixBytes.baseAddress, count) == 0
            }
        }
        if let result = fast ?? nil { return result }
        return text.utf8.starts(with: prefix.utf8)
    }
}
