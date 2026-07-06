import CmuxAgentChat
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// The core prose bubble: user prompts render trailing-aligned plain text
/// on the outgoing fill; agent prose renders leading-aligned with markdown
/// text runs and embedded monospace code blocks.
public struct ChatProseBubbleView: View {
    private let prose: ChatProse
    private let message: ChatMessage
    private let groupPosition: ChatGroupPosition
    private let showsTimestamp: Bool
    private let onShowCodeDetail: (String, String?) -> Void

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatBubbleMaxWidth) private var bubbleMaxWidth
    @Environment(\.chatContentCache) private var contentCache
    @Environment(\.chatMarkdownRenderer) private var renderer

    /// Creates a prose bubble.
    ///
    /// - Parameters:
    ///   - prose: The text payload.
    ///   - message: The owning message (role, timestamp, identity).
    ///   - groupPosition: Position inside the visual bubble group.
    ///   - showsTimestamp: Whether the group timestamp renders under this
    ///     bubble.
    ///   - onShowCodeDetail: Opens full code block text outside the row.
    public init(
        prose: ChatProse,
        message: ChatMessage,
        groupPosition: ChatGroupPosition,
        showsTimestamp: Bool,
        onShowCodeDetail: @escaping (String, String?) -> Void = { _, _ in }
    ) {
        self.prose = prose
        self.message = message
        self.groupPosition = groupPosition
        self.showsTimestamp = showsTimestamp
        self.onShowCodeDetail = onShowCodeDetail
    }

    public var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 64) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                bubble
                    .frame(maxWidth: bubbleMaxWidth, alignment: isUser ? .trailing : .leading)
                    .contextMenu {
                        Button(action: copyProse) {
                            Label(
                                String(localized: "chat.bubble.copy", defaultValue: "Copy", bundle: .module),
                                systemImage: "doc.on.doc"
                            )
                        }
                    }
                if showsTimestamp {
                    Text(message.timestamp.formatted(.dateTime.hour().minute()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAction(
                named: Text(
                    String(localized: "chat.bubble.copy", defaultValue: "Copy", bundle: .module)
                ),
                copyProse
            )
            if !isUser { Spacer(minLength: 64) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var isUser: Bool { message.role == .user }

    /// Copies the bubble's full prose text to the system pasteboard; shared
    /// by the context menu and the VoiceOver custom action.
    private func copyProse() {
        #if canImport(UIKit)
        UIPasteboard.general.string = prose.text
        #endif
    }

    private var proseSegments: [ChatProseSegment] {
        contentCache?.proseSegments(messageID: message.id, text: prose.text)
            ?? ChatProseSegmenter().segments(from: prose.text)
    }

    private static let codeBlockLineCap = 8

    private var bubble: some View {
        Group {
            if isUser {
                Text(prose.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(proseSegments) { segment in
                        segmentView(segment)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            isUser ? theme.outgoingBubbleFill : theme.incomingBubbleFill,
            in: bubbleShape
        )
    }

    @ViewBuilder
    private func segmentView(_ segment: ChatProseSegment) -> some View {
        switch segment.kind {
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(textBlocks(for: segment)) { block in
                    blockView(block, segmentIndex: segment.index)
                }
            }
        case .code(let language):
            let codeLines = segment.content
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            let visibleCode = codeLines.count > Self.codeBlockLineCap
                ? codeLines.prefix(Self.codeBlockLineCap).joined(separator: "\n")
                : segment.content
            Button {
                onShowCodeDetail(segment.content, language)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    codeHeader(language: language)
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(verbatim: visibleCode.isEmpty ? " " : visibleCode)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(theme.terminalCardText)
                            .padding(8)
                    }
                    if codeLines.count > Self.codeBlockLineCap {
                        Text(
                            String(
                                localized: "chat.terminal.more_lines",
                                defaultValue: "⋯ \(codeLines.count - Self.codeBlockLineCap) more lines",
                                bundle: .module
                            )
                        )
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                    }
                }
                .background(theme.terminalCardFill, in: .rect(cornerRadius: 8))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ChatCodeBlockDetail-\(message.id)-\(segment.index)")
            .accessibilityLabel(
                String(localized: "chat.detail.show.accessibility", defaultValue: "Show details", bundle: .module)
            )
            .accessibilityHint(
                String(
                    localized: "chat.detail.show.hint",
                    defaultValue: "Opens a sheet with the full block content",
                    bundle: .module
                )
            )
        }
    }

    private func codeHeader(language: String?) -> some View {
        HStack(spacing: 6) {
            if let language, !language.isEmpty {
                Text(verbatim: language.uppercased())
                    .accessibilityLabel(
                        String(
                            localized: "chat.code.language.accessibility",
                            defaultValue: "\(language) code",
                            bundle: .module
                        )
                    )
            } else {
                Text(
                    String(localized: "chat.detail.code.section", defaultValue: "Code", bundle: .module)
                )
            }
            Spacer(minLength: 6)
            Image(systemName: "doc.text.magnifyingglass")
                .font(.caption2)
                .accessibilityHidden(true)
        }
        .font(.system(size: 10, weight: .semibold, design: .monospaced))
        .foregroundStyle(theme.terminalCardText.opacity(0.6))
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    /// Block-level elements of a text segment (headings, lists, quotes,
    /// paragraphs), cached alongside the ANSI/segment work.
    private func textBlocks(for segment: ChatProseSegment) -> [ChatTextBlock] {
        contentCache?.textBlocks(messageID: "\(message.id)#\(segment.index)", text: segment.content)
            ?? ChatTextBlockParser().blocks(from: segment.content)
    }

    /// Renders one block with its structural styling; inline markdown
    /// (bold/italic/code/links) comes from the shared renderer.
    @ViewBuilder
    private func blockView(_ block: ChatTextBlock, segmentIndex: Int) -> some View {
        let inline = renderedInline(block.text, segmentIndex: segmentIndex, blockIndex: block.index)
        switch block.kind {
        case .heading(let level):
            Text(inline)
                .font(headingFont(level: level))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.top, block.index == 0 ? 0 : 2)
        case .paragraph:
            Text(inline)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        case .bullet(let indent):
            listRow(marker: "•", inline: inline, indent: indent)
        case .ordered(let marker, let indent):
            listRow(marker: marker, inline: inline, indent: indent)
        case .quote:
            HStack(spacing: 8) {
                Rectangle()
                    .fill(theme.hairline)
                    .frame(width: 3)
                Text(inline)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .rule:
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .accessibilityHidden(true)
        }
    }

    private func listRow(marker: String, inline: AttributedString, indent: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            Text(inline)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(min(indent, 4)) * 14)
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title3.weight(.bold)
        case 2: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    /// Inline-markdown render of a block's text through the shared cache.
    private func renderedInline(_ text: String, segmentIndex: Int, blockIndex: Int) -> AttributedString {
        renderer?.render(messageID: "\(message.id)#\(segmentIndex).\(blockIndex)", markdown: text)
            ?? AttributedString(text)
    }

    /// The bubble outline: full radius everywhere except the grouped inner
    /// corners on the bubble's aligned side, which tighten so consecutive
    /// same-author bubbles read as one group.
    private var bubbleShape: UnevenRoundedRectangle {
        let full = theme.bubbleCornerRadius
        let tight = theme.bubbleGroupedCornerRadius
        let tightTop = groupPosition == .middle || groupPosition == .last
        let tightBottom = groupPosition == .first || groupPosition == .middle
        if isUser {
            return UnevenRoundedRectangle(
                topLeadingRadius: full,
                bottomLeadingRadius: full,
                bottomTrailingRadius: tightBottom ? tight : full,
                topTrailingRadius: tightTop ? tight : full
            )
        }
        return UnevenRoundedRectangle(
            topLeadingRadius: tightTop ? tight : full,
            bottomLeadingRadius: tightBottom ? tight : full,
            bottomTrailingRadius: full,
            topTrailingRadius: full
        )
    }
}
