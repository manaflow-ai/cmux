import Foundation

/// Preserve Markdown's block boundaries when handing attributed text to SwiftUI.
/// `Text` renders inline attributes but does not lay out presentation intents.
struct AgentMarkdownDocument {
    struct Block: Identifiable {
        enum Kind: Equatable {
            case prose
            case heading(Int)
            case code(String?)
            case table
        }

        let id: Int
        var kind: Kind
        var text: AttributedString
        var listMarker: String?
        var listDepth: Int
        var isQuote: Bool
        var rows: [[AttributedString]] = []
    }

    let blocks: [Block]

    init(markdown: String) {
        let parsed = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(markdown)
        var blocks: [Block] = []
        var tableID: Int?

        for (intent, range) in parsed.runs[\.presentationIntent] {
            let components = intent?.components ?? []
            var text = AttributedString(parsed[range])
            // The structural intent is rendered below. Retain links, emphasis,
            // inline code, and every other inline attribute in this substring.
            text.presentationIntent = nil
            var kind: Block.Kind = .prose
            var marker: String?
            var depth = 0
            var quote = false
            var currentTableID: Int?
            var row = 0
            var column = 0
            let isOrdered = components.first(where: {
                switch $0.kind {
                case .orderedList, .unorderedList: true
                default: false
                }
            })?.kind == .orderedList

            for component in components {
                switch component.kind {
                case .header(let level): kind = .heading(level)
                case .codeBlock(let language): kind = .code(language)
                case .listItem(let ordinal):
                    if marker == nil { marker = isOrdered ? "\(ordinal)." : "•" }
                case .orderedList, .unorderedList: depth += 1
                case .blockQuote: quote = true
                case .table:
                    currentTableID = component.identity
                case .tableRow(let index): row = index
                case .tableCell(let index): column = index
                default: break
                }
            }

            if let currentTableID {
                if tableID != currentTableID {
                    blocks.append(Block(id: blocks.count, kind: .table, text: AttributedString(), listDepth: 0, isQuote: quote))
                    tableID = currentTableID
                }
                let index = blocks.count - 1
                while blocks[index].rows.count <= row { blocks[index].rows.append([]) }
                while blocks[index].rows[row].count <= column { blocks[index].rows[row].append(AttributedString()) }
                blocks[index].rows[row][column].append(text)
            } else {
                tableID = nil
                guard !text.characters.isEmpty else { continue }
                blocks.append(Block(
                    id: blocks.count, kind: kind, text: text, listMarker: marker,
                    listDepth: depth, isQuote: quote
                ))
            }
        }
        self.blocks = blocks
    }
}
