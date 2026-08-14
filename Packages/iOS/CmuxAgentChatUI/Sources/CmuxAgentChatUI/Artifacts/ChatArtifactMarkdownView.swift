import Foundation
import SwiftUI

/// Renders document-level Markdown with Foundation's native syntax support.
struct ChatArtifactMarkdownView: View {
    let markdown: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(ChatArtifactMarkdownDocument(markdown: markdown).blocks) { block in
                    blockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    @ViewBuilder
    private func blockView(_ block: ChatArtifactMarkdownBlock) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(renderedInline(block.text))
                .font(headingFont(level: level))
                .textSelection(.enabled)
                .padding(.top, block.index == 0 ? 0 : 4)
        case .paragraph:
            Text(renderedInline(block.text))
                .font(.body)
                .textSelection(.enabled)
        case .bullet(let indent):
            listRow(marker: "•", text: block.text, indent: indent)
        case .ordered(let marker, let indent):
            listRow(marker: marker, text: block.text, indent: indent)
        case .quote:
            HStack(spacing: 10) {
                Rectangle()
                    .fill(.tertiary)
                    .frame(width: 3)
                Text(renderedInline(block.text))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .rule:
            Divider()
                .padding(.vertical, 4)
        case .code(let language):
            VStack(alignment: .leading, spacing: 6) {
                if let language, !language.isEmpty {
                    Text(verbatim: language.uppercased())
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(.secondary)
                }
                ScrollView(.horizontal) {
                    Text(verbatim: block.text.isEmpty ? " " : block.text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.1), in: .rect(cornerRadius: 8))
        case .tableRow(let isHeader):
            ScrollView(.horizontal) {
                Text(verbatim: block.text)
                    .font(.system(.body, design: .monospaced).weight(isHeader ? .semibold : .regular))
                    .textSelection(.enabled)
            }
            .padding(.vertical, isHeader ? 4 : 0)
        }
    }

    private func listRow(marker: String, text: String, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: marker)
                .foregroundStyle(.secondary)
                .frame(minWidth: 20, alignment: .trailing)
            Text(renderedInline(text))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.leading, CGFloat(min(indent, 4)) * 16)
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: .title.weight(.bold)
        case 2: .title2.weight(.bold)
        case 3: .title3.weight(.semibold)
        default: .headline
        }
    }

    private func renderedInline(_ markdown: String) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: markdown, options: options))
            ?? AttributedString(markdown)
    }
}
