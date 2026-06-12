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
    public init(
        prose: ChatProse,
        message: ChatMessage,
        groupPosition: ChatGroupPosition,
        showsTimestamp: Bool
    ) {
        self.prose = prose
        self.message = message
        self.groupPosition = groupPosition
        self.showsTimestamp = showsTimestamp
    }

    public var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 64) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                bubble
                    .frame(maxWidth: bubbleMaxWidth, alignment: isUser ? .trailing : .leading)
                    .contextMenu {
                        Button {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = prose.text
                            #endif
                        } label: {
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
            if !isUser { Spacer(minLength: 64) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private var isUser: Bool { message.role == .user }

    private var proseSegments: [ChatProseSegment] {
        contentCache?.proseSegments(messageID: message.id, text: prose.text)
            ?? ChatProseSegmenter().segments(from: prose.text)
    }

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
            Text(renderedText(for: segment))
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        case .code:
            ScrollView(.horizontal, showsIndicators: false) {
                Text(segment.content)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.terminalCardText)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(theme.terminalCardFill, in: .rect(cornerRadius: 8))
        }
    }

    /// Markdown-renders a text segment through the shared cache, falling
    /// back to plain attributed text when no renderer is in the environment
    /// (previews).
    private func renderedText(for segment: ChatProseSegment) -> AttributedString {
        renderer?.render(messageID: "\(message.id)#\(segment.index)", markdown: segment.content)
            ?? AttributedString(segment.content)
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
