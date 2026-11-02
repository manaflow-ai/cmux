#if os(iOS)
import CmuxMobileDesign
import SwiftUI
import UIKit

/// Native markdown for transcripts (SPEC 2.2, 4.6, 4.7, 6.3). Display math and
/// paragraphs with inline math go through the pooled web renderer, the only
/// complete TeX layout available on iOS.
public struct MarkdownView: View {
    let document: MarkdownDocument
    /// Horizontal margin of the column; tables bleed past it to the screen edge.
    var margin: CGFloat
    var isStreaming: Bool
    /// false: blocks appear in place (a transcript's replayed history), with no fade in.
    var animatesBlocks: Bool
    /// Find in Chat's marks on the blocks (nil: none).
    var marks: (any MarkdownBlockMarks)?

    public init(_ document: MarkdownDocument, margin: CGFloat = 20, isStreaming: Bool = false, animatesBlocks: Bool = true,
                marks: (any MarkdownBlockMarks)? = nil) {
        self.document = document
        self.margin = margin
        self.isStreaming = isStreaming
        self.animatesBlocks = animatesBlocks
        self.marks = marks
    }

    public init(markdown: String, margin: CGFloat = 20) {
        self.init(MarkdownDocument(parsing: markdown), margin: margin)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(document.blocks) { block in
                MarkdownBlockView(block: block, margin: margin)
                    .modifier(MarkdownBlockMarker(block: block.id, marks: marks))
                    .transition(animatesBlocks ? .opacity.animation(.easeOut(duration: 0.15)) : .identity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Locates and marks a `MarkdownView`'s blocks from outside: Find in Chat scrolls to the block
/// (paragraph, list, code card, table) that holds a match and marks it. Read while each block
/// draws, so an observable source redraws only the marks, never the block, when it changes.
@MainActor
public protocol MarkdownBlockMarks: Sendable {
    /// The named coordinate space the blocks' frames are reported in.
    var frameSpace: String { get }
    /// Whether the block (`MarkdownBlock.id`) is drawn marked.
    func isMarked(_ block: Int) -> Bool
    /// The block's frame in `frameSpace`, each time it lays out.
    func laidOut(_ block: Int, frame: CGRect)
}

struct MarkdownBlockMarker: ViewModifier {
    let block: Int
    let marks: (any MarkdownBlockMarks)?

    func body(content: Content) -> some View {
        if let marks {
            let marked = marks.isMarked(block)
            let space = marks.frameSpace
            content
                .background {
                    if marked {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.yellow.opacity(0.28))
                            .padding(-6)
                            .accessibilityHidden(true)
                    }
                }
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(space))
                } action: { [block] frame in
                    marks.laidOut(block, frame: frame)
                }
                .accessibilityAddTraits(marked ? .isSelected : [])
        } else {
            content
        }
    }
}

/// One block of a markdown document (a transcript draws a long answer block by block).
public struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let margin: CGFloat

    public init(block: MarkdownBlock, margin: CGFloat = 20) {
        self.block = block
        self.margin = margin
    }

    public var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            InlineText(source: text, font: headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            if MarkdownInlineMath.contains(text) {
                WebMarkdownView(markdown: text, style: .body)
            } else {
                InlineText(source: text)
                    .textSelection(.enabled)
            }
        case .list(let list):
            MarkdownListView(list: list)
        case .code(let language, let code, _):
            CodeCard(language: language, code: code)
        case .table(let table):
            MarkdownTableView(table: table, margin: margin)
        case .quote(let text):
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(uiColor: .separator)).frame(width: 3)
                InlineText(source: text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .math(let tex):
            WebMarkdownView(markdown: "$$\n\(tex)\n$$", style: .body)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3.bold()
        case 2: .headline
        default: .subheadline.bold()
        }
    }
}

struct MarkdownListView: View {
    let list: MarkdownList

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(list.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(item)
                        .frame(minWidth: 14, alignment: .trailing)
                    InlineText(source: item.text)
                }
                .padding(.leading, CGFloat(item.depth) * 20 + 4)
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: MarkdownList.Item) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(.subheadline)
                .foregroundStyle(checked ? Color.cmuxMobileSuccess : .secondary)
        } else if let ordinal = item.ordinal {
            Text("\(ordinal).").font(.body.monospacedDigit()).foregroundStyle(.secondary)
        } else {
            Text(item.depth == 0 ? "•" : "◦").font(.body).foregroundStyle(.secondary)
        }
    }
}

/// SPEC 4.7: grid in a horizontal scroll view that bleeds to the screen edges.
struct MarkdownTableView: View {
    let table: MarkdownTable
    let margin: CGFloat

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(0..<table.columnCount, id: \.self) { column in
                        cell(table.header[safe: column] ?? "", column: column, header: true)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<table.columnCount, id: \.self) { column in
                            cell(row[safe: column] ?? "", column: column, header: false)
                        }
                    }
                }
            }
            .padding(.horizontal, margin - 12)
        }
        .scrollIndicators(.hidden)
        .trailingOverflowFade()
        .padding(.horizontal, -margin)
        .contextMenu {
            Button("Copy Table", systemImage: "doc.on.doc") { UIPasteboard.general.string = table.plainText }
        }
    }

    private func cell(_ text: String, column: Int, header: Bool) -> some View {
        // In a horizontal scroll view the grid measures cells with no width
        // proposal (one line), so a wrapped cell kept a one-line row height
        // and ran into the row separators. The layout reports the height at
        // the capped width instead.
        TableCellLayout(minWidth: 96 - 24, maxWidth: 260 - 24) {
            InlineText(source: text, font: header ? .subheadline.weight(.semibold) : .subheadline)
                .frame(maxWidth: .infinity, alignment: alignment(column))
        }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    private func alignment(_ column: Int) -> Alignment {
        switch table.alignments[safe: column] ?? .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Sizes one table cell: its ideal width clamped to `minWidth...maxWidth`,
/// and the height its content needs at that width.
struct TableCellLayout: Layout {
    let minWidth: CGFloat
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(.unspecified).width
        let proposed = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let width = min(max(proposed.map { min($0, ideal) } ?? ideal, minWidth), maxWidth)
        let height = content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: proposed.map { max(min($0, maxWidth), width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
