import Foundation

/// Parses Markdown into stable block-level values before SwiftUI lays it out.
struct ChatArtifactMarkdownDocument: Equatable, Sendable {
    let blocks: [ChatArtifactMarkdownBlock]

    init(markdown: String) {
        var parsed: [ChatArtifactMarkdownBlock] = []
        for segment in ChatProseSegmenter().segments(from: markdown) {
            switch segment.kind {
            case .text:
                for textBlock in ChatTextBlockParser().blocks(from: segment.content) {
                    parsed.append(contentsOf: Self.blocks(from: textBlock))
                }
            case .code(let language):
                parsed.append(ChatArtifactMarkdownBlock(
                    index: parsed.count,
                    kind: .code(language: language),
                    text: segment.content
                ))
            }
        }
        blocks = parsed.enumerated().map { index, block in
            ChatArtifactMarkdownBlock(index: index, kind: block.kind, text: block.text)
        }
    }

    private static func blocks(from block: ChatTextBlock) -> [ChatArtifactMarkdownBlock] {
        switch block.kind {
        case .heading(let level):
            return [markdownBlock(kind: .heading(level: level), text: block.text)]
        case .paragraph:
            return paragraphBlocks(from: block.text)
        case .bullet(let indent):
            return [markdownBlock(kind: .bullet(indent: indent), text: block.text)]
        case .ordered(let marker, let indent):
            return [markdownBlock(kind: .ordered(marker: marker, indent: indent), text: block.text)]
        case .quote:
            return [markdownBlock(kind: .quote, text: block.text)]
        case .rule:
            return [markdownBlock(kind: .rule, text: "")]
        }
    }

    /// Splits GitHub-style tables out of paragraph runs while preserving surrounding prose.
    private static func paragraphBlocks(from text: String) -> [ChatArtifactMarkdownBlock] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [ChatArtifactMarkdownBlock] = []
        var paragraphLines: [String] = []
        var index = 0

        while index < lines.count {
            let startsTable = index + 1 < lines.count
                && tableCells(in: lines[index]) != nil
                && isTableSeparator(lines[index + 1])
            if !startsTable {
                paragraphLines.append(lines[index])
                index += 1
                continue
            }

            if !paragraphLines.isEmpty {
                result.append(markdownBlock(
                    kind: .paragraph,
                    text: paragraphLines.joined(separator: "\n")
                ))
                paragraphLines.removeAll(keepingCapacity: true)
            }

            if let headerCells = tableCells(in: lines[index]) {
                result.append(markdownBlock(
                    kind: .tableRow(isHeader: true),
                    text: headerCells.joined(separator: " │ ")
                ))
            }
            index += 2
            while index < lines.count, let cells = tableCells(in: lines[index]) {
                result.append(markdownBlock(
                    kind: .tableRow(isHeader: false),
                    text: cells.joined(separator: " │ ")
                ))
                index += 1
            }
        }

        if !paragraphLines.isEmpty {
            result.append(markdownBlock(
                kind: .paragraph,
                text: paragraphLines.joined(separator: "\n")
            ))
        }
        return result
    }

    private static func tableCells(in line: String) -> [String]? {
        let cells = line
            .split(separator: "|", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard cells.count >= 2, cells.allSatisfy({ !$0.isEmpty }) else { return nil }
        return cells
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard let cells = tableCells(in: line) else { return false }
        return cells.allSatisfy { cell in
            let withoutColons = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            return withoutColons.count >= 3 && withoutColons.allSatisfy { $0 == "-" }
        }
    }

    private static func markdownBlock(
        kind: ChatArtifactMarkdownBlock.Kind,
        text: String
    ) -> ChatArtifactMarkdownBlock {
        ChatArtifactMarkdownBlock(index: 0, kind: kind, text: text)
    }
}
