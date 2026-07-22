import CmuxAgentChat
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// An outgoing attachment bubble. Images reserve a stable inline preview;
/// other files keep a compact filename-and-path treatment.
public struct ChatAttachmentBubbleView: View {
    private let attachment: ChatAttachment
    private let groupPosition: ChatGroupPosition
    private let showsTimestamp: Bool
    private let timestamp: Date
    private let onOpenArtifact: ((String) -> Void)?

    @Environment(\.chatTheme) private var theme
    @Environment(\.chatBubbleMaxWidth) private var bubbleMaxWidth
    @Environment(\.chatArtifactLoader) private var artifactLoader

    @State private var thumbnailData: Data?
    @State private var thumbnailFailed = false
    @State private var thumbnailRequest: ChatAttachmentThumbnailRequest?
    @State private var fallbackSelection: ChatArtifactPathSelection?

    /// Creates an attachment bubble.
    ///
    /// - Parameters:
    ///   - attachment: The attachment metadata.
    ///   - groupPosition: Position inside the visual bubble group.
    ///   - showsTimestamp: Whether the group timestamp renders under this
    ///     bubble.
    ///   - timestamp: When the attachment was sent.
    ///   - onOpenArtifact: Pushes the host path inline when the caller owns a
    ///     navigation stack. When omitted, the standalone bubble uses a sheet.
    public init(
        attachment: ChatAttachment,
        groupPosition: ChatGroupPosition,
        showsTimestamp: Bool,
        timestamp: Date,
        onOpenArtifact: ((String) -> Void)? = nil
    ) {
        self.attachment = attachment
        self.groupPosition = groupPosition
        self.showsTimestamp = showsTimestamp
        self.timestamp = timestamp
        self.onOpenArtifact = onOpenArtifact
    }

    public var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 64)
            VStack(alignment: .trailing, spacing: 3) {
                attachmentContent
                    .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
                if showsTimestamp {
                    Text(timestamp.formatted(.dateTime.hour().minute()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .sheet(item: $fallbackSelection) { selection in
            ChatArtifactViewerSheet(path: selection.path)
        }
    }

    @ViewBuilder
    private var attachmentContent: some View {
        switch attachment.media {
        case .image:
            imageAttachment
        case .file:
            fileAttachment
        }
    }

    @ViewBuilder
    private var imageAttachment: some View {
        if let hostPath {
            Button {
                openArtifact(path: hostPath)
            } label: {
                imagePreview
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(displayName)
            .accessibilityHint(openPreviewHint)
            .accessibilityIdentifier("ChatAttachmentImagePreview")
            .task(id: currentThumbnailRequest) {
                guard let request = currentThumbnailRequest else { return }
                await loadThumbnail(request: request)
            }
        } else {
            imagePreview
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(displayName)
                .accessibilityIdentifier("ChatAttachmentImagePreview")
        }
    }

    @ViewBuilder
    private var fileAttachment: some View {
        if artifactLoader.supportsArtifacts, let hostPath {
            Button {
                openArtifact(path: hostPath)
            } label: {
                fileBubble
            }
            .buttonStyle(.plain)
            .accessibilityLabel(displayName)
            .accessibilityHint(openPreviewHint)
        } else {
            fileBubble
                .accessibilityElement(children: .combine)
                .accessibilityLabel(displayName)
        }
    }

    private var fileBubble: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "doc")
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

    private var imagePreview: some View {
        ZStack {
            theme.terminalCardFill
            imagePreviewContent
        }
        .aspectRatio(previewLayout.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(bubbleShape)
        .overlay {
            bubbleShape
                .stroke(theme.hairline.opacity(0.7), lineWidth: 0.5)
        }
        .contentShape(bubbleShape)
    }

    @ViewBuilder
    private var imagePreviewContent: some View {
        if let currentThumbnailRequest,
           thumbnailRequest == currentThumbnailRequest,
           let thumbnailData {
            #if canImport(UIKit)
            if let image = UIImage(data: thumbnailData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailablePreview
            }
            #elseif canImport(AppKit)
            if let image = NSImage(data: thumbnailData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                unavailablePreview
            }
            #else
            unavailablePreview
            #endif
        } else if !artifactLoader.supportsArtifacts
            || hostPath == nil
            || (thumbnailRequest == currentThumbnailRequest && thumbnailFailed) {
            unavailablePreview
        } else {
            ProgressView()
                .controlSize(.small)
                .tint(.white.opacity(0.82))
        }
    }

    private var unavailablePreview: some View {
        VStack(spacing: 7) {
            Image(systemName: "photo")
                .font(.title2)
            Text(
                String(
                    localized: "chat.artifact.preview_unavailable.title",
                    defaultValue: "Preview unavailable",
                    bundle: .module
                )
            )
            .font(.caption)
        }
        .foregroundStyle(.white.opacity(0.82))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewLayout: ChatAttachmentPreviewLayout {
        ChatAttachmentPreviewLayout(
            pixelWidth: attachment.pixelWidth,
            pixelHeight: attachment.pixelHeight
        )
    }

    private var hostPath: String? {
        guard let hostPath = attachment.hostPath, !hostPath.isEmpty else { return nil }
        return hostPath
    }

    private var currentThumbnailRequest: ChatAttachmentThumbnailRequest? {
        guard let hostPath else { return nil }
        return ChatAttachmentThumbnailRequest(
            path: hostPath,
            scope: artifactLoader.scope,
            supportsArtifacts: artifactLoader.supportsArtifacts,
            byteCount: attachment.byteCount.map(Int64.init)
        )
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
        switch attachment.media {
        case .image:
            return String(localized: "chat.attachment.image", defaultValue: "Image", bundle: .module)
        case .file:
            return String(localized: "chat.attachment.file", defaultValue: "File", bundle: .module)
        }
    }

    private var openPreviewHint: String {
        String(
            localized: "chat.attachment.open_preview_hint",
            defaultValue: "Opens the full preview",
            bundle: .module
        )
    }

    private func openArtifact(path: String) {
        if let onOpenArtifact {
            onOpenArtifact(path)
        } else {
            fallbackSelection = ChatArtifactPathSelection(path: path)
        }
    }

    private func loadThumbnail(request: ChatAttachmentThumbnailRequest) async {
        if thumbnailRequest != request {
            thumbnailRequest = request
            thumbnailData = nil
            thumbnailFailed = false
        }
        guard request.supportsArtifacts else {
            thumbnailFailed = true
            return
        }
        guard thumbnailData == nil, !thumbnailFailed else { return }
        do {
            let thumbnail = try await artifactLoader.thumbnail(
                path: request.path,
                maxDimension: 1_024,
                size: request.byteCount
            )
            guard !Task.isCancelled, thumbnailRequest == request else { return }
            thumbnailData = thumbnail.data
        } catch is CancellationError {
            return
        } catch {
            guard thumbnailRequest == request else { return }
            thumbnailFailed = true
        }
    }
}

private struct ChatAttachmentThumbnailRequest: Hashable {
    let path: String
    let scope: ChatArtifactLoaderScope
    let supportsArtifacts: Bool
    let byteCount: Int64?
}
