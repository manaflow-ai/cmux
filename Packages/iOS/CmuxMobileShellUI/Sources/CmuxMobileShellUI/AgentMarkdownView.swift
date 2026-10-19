import SwiftUI

/// Native conversation Markdown, with horizontal scrolling limited to code
/// and tables so long output cannot widen the surrounding transcript.
struct AgentMarkdownView: View {
    private let document: AgentMarkdownDocument
    let color: Color

    init(markdown: String, color: Color = .primary) {
        document = AgentMarkdownDocument(markdown: markdown)
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(document.blocks) { block in
                HStack(alignment: .top, spacing: 10) {
                    if block.isQuote {
                        Rectangle()
                            .fill(.secondary.opacity(0.4))
                            .frame(width: 3)
                    }
                    if let marker = block.listMarker {
                        Text(marker).monospacedDigit()
                            .frame(minWidth: 16, alignment: .trailing)
                    }
                    blockContent(block)
                }
                .padding(.leading, CGFloat(max(0, block.listDepth - 1)) * 16)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.body)
        .foregroundStyle(color)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockContent(_ block: AgentMarkdownDocument.Block) -> some View {
        switch block.kind {
        case .prose:
            Text(block.text).frame(maxWidth: .infinity, alignment: .leading)
        case .heading(let level):
            Text(block.text)
                .font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language):
            VStack(alignment: .leading, spacing: 8) {
                if let language, !language.isEmpty {
                    Text(language).font(.caption).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(block.text)
                        .font(.callout.monospaced())
                        .fixedSize(horizontal: true, vertical: true)
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("MobileAgentMarkdownCode")
        case .table:
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(block.rows.enumerated()), id: \.offset) { rowIndex, cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                Text(cell)
                                    .fontWeight(rowIndex == 0 ? .semibold : .regular)
                                    .frame(minWidth: 100, maxWidth: 240, alignment: .leading)
                                    .padding(10)
                            }
                        }
                        .background(rowIndex.isMultiple(of: 2) ? Color(.secondarySystemBackground) : .clear)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("MobileAgentMarkdownTable")
        }
    }
}
