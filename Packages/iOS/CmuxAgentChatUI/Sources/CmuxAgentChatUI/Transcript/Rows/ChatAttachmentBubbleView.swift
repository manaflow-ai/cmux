import CmuxAgentChat
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An outgoing attachment bubble: a photo glyph plus the attachment's
/// display name, with the host-side path when known.
public struct ChatAttachmentBubbleView: View {
    private let attachment: ChatAttachment
    private let groupPosition: ChatGroupPosition
    private let showsTimestamp: Bool
    private let timestamp: Date

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatBubbleMaxWidth) private var bubbleMaxWidth
    @Environment(\.chatArtifactLoader) private var artifactLoader

    @State private var thumbnailData: Data?
    @State private var thumbnailFailed = false
    @State private var thumbnailPath: String?
    @State private var selectedArtifact: ChatArtifactPathSelection?

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
                artifactAwareBubble
                    .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
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
        .sheet(item: $selectedArtifact) { selection in
            ChatArtifactViewerSheet(path: selection.path)
        }
    }

    @ViewBuilder
    private var artifactAwareBubble: some View {
        if artifactLoader.supportsArtifacts, let hostPath = attachment.hostPath, !hostPath.isEmpty {
            Button {
                selectedArtifact = ChatArtifactPathSelection(path: hostPath)
            } label: {
                if thumbnailFailed {
                    bubble
                } else {
                    thumbnailBubble(hostPath: hostPath)
                }
            }
            .buttonStyle(.plain)
            .task(id: hostPath) {
                await loadThumbnail(path: hostPath)
            }
        } else {
            bubble
        }
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

    private func thumbnailBubble(hostPath: String) -> some View {
        HStack(spacing: 8) {
            thumbnailImage
                .frame(width: 48, height: 48)
                .background(.white.opacity(0.16), in: .rect(cornerRadius: 6))
                .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.caption)
                    Text(displayName)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(hostPath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(theme.outgoingBubbleFill, in: bubbleShape)
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if let thumbnailData {
            #if canImport(UIKit)
            if let image = UIImage(data: thumbnailData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholderThumbnail
            }
            #elseif canImport(AppKit)
            if let image = NSImage(data: thumbnailData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholderThumbnail
            }
            #else
            placeholderThumbnail
            #endif
        } else {
            placeholderThumbnail
        }
    }

    private var placeholderThumbnail: some View {
        Image(systemName: "photo")
            .font(.title3)
            .foregroundStyle(.white.opacity(0.82))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func loadThumbnail(path: String) async {
        if thumbnailPath != path {
            thumbnailPath = path
            thumbnailData = nil
            thumbnailFailed = false
        }
        guard thumbnailData == nil, !thumbnailFailed else { return }
        do {
            thumbnailData = try await artifactLoader.thumbnail(path: path, maxDimension: 256).data
        } catch {
            thumbnailFailed = true
        }
    }
}
