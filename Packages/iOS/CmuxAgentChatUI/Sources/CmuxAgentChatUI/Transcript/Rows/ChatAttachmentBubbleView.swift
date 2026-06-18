import CmuxAgentChat
import SwiftUI

/// An outgoing attachment bubble: a photo glyph plus the attachment's
/// display name, with the host-side path when known.
public struct ChatAttachmentBubbleView: View {
    private let attachment: ChatAttachment
    private let groupPosition: ChatGroupPosition
    private let showsTimestamp: Bool
    private let timestamp: Date

    @Environment(\.chatTheme) private var theme

    /// Creates an attachment bubble.
    ///
    /// - Parameters:
    ///   - attachment: The attachment metadata.
    ///   - groupPosition: Position inside the visual bubble group.
    ///   - showsTimestamp: Whether the group timestamp renders under this
    ///     bubble.
    ///   - timestamp: When the attachment was sent.
    public init(
        attachment: ChatAttachment,
        groupPosition: ChatGroupPosition,
        showsTimestamp: Bool,
        timestamp: Date
    ) {
        self.attachment = attachment
        self.groupPosition = groupPosition
        self.showsTimestamp = showsTimestamp
        self.timestamp = timestamp
    }

    public var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: 3) {
                bubble
                if showsTimestamp {
                    Text(timestamp.formatted(.dateTime.hour().minute()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.caption)
                Text(displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.white)
            if let hostPath = attachment.hostPath, !hostPath.isEmpty {
                Text(hostPath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.outgoingBubbleFill, in: bubbleShape)
    }

    /// Trailing-side grouped-corner shape matching the prose bubble rules.
    private var bubbleShape: UnevenRoundedRectangle {
        let full = theme.bubbleCornerRadius
        let tight = theme.bubbleGroupedCornerRadius
        let tightTop = groupPosition == .middle || groupPosition == .last
        let tightBottom = groupPosition == .first || groupPosition == .middle
        return UnevenRoundedRectangle(
            topLeadingRadius: full,
            bottomLeadingRadius: full,
            bottomTrailingRadius: tightBottom ? tight : full,
            topTrailingRadius: tightTop ? tight : full
        )
    }

    private var displayName: String {
        if let name = attachment.displayName, !name.isEmpty {
            return name
        }
        return String(localized: "chat.attachment.image", defaultValue: "Image", bundle: .module)
    }
}
