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
    private let role: ChatRole
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
    @State private var thumbnailRetryAttempt = 0
    @State private var fallbackSelection: ChatArtifactPathSelection?

    /// Creates an attachment bubble.
    ///
    /// - Parameters:
    ///   - attachment: The attachment metadata.
    ///   - role: Who authored the attachment row.
    ///   - groupPosition: Position inside the visual bubble group.
    ///   - showsTimestamp: Whether the group timestamp renders under this
    ///     bubble.
    ///   - timestamp: When the attachment was sent.
    ///   - onOpenArtifact: Pushes the host path inline when the caller owns a
    ///     navigation stack. When omitted, the standalone bubble uses a sheet.
    public init(
        attachment: ChatAttachment,
        role: ChatRole = .user,
        groupPosition: ChatGroupPosition,
        showsTimestamp: Bool,
        timestamp: Date,
        onOpenArtifact: ((String) -> Void)? = nil
    ) {
        self.attachment = attachment
        self.role = role
        self.groupPosition = groupPosition
        self.showsTimestamp = showsTimestamp
        self.timestamp = timestamp
        self.onOpenArtifact = onOpenArtifact
    }

    public var body: some View {
        HStack(spacing: 0) {
            if isUser { Spacer(minLength: 64) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                attachmentContent
                    .frame(maxWidth: bubbleMaxWidth, alignment: isUser ? .trailing : .leading)
                if showsTimestamp {
                    Text(timestamp.formatted(.dateTime.hour().minute()))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4)
                }
            }
            if !isUser { Spacer(minLength: 64) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .sheet(item: $fallbackSelection) { selection in
            ChatArtifactViewerSheet(path: selection.path)
                .environment(\.chatArtifactLoader, artifactLoader)
        }
    }

    private var isUser: Bool { role == .user }

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
            .accessibilityLabel(displayName)
            .accessibilityHint(openPreviewHint)
            .accessibilityIdentifier("ChatAttachmentImagePreview")
            .task(id: currentThumbnailTaskID) {
                guard let taskID = currentThumbnailTaskID else { return }
                await loadThumbnail(taskID: taskID)
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
            .foregroundStyle(fileBubbleTextStyle)
            if let hostPath = attachment.hostPath, !hostPath.isEmpty {
                Text(hostPath)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(fileBubbleSecondaryTextStyle)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isUser ? theme.outgoingBubbleFill : theme.incomingBubbleFill, in: bubbleShape)
    }

    private var fileBubbleTextStyle: Color {
        isUser ? .white : .primary
    }

    private var fileBubbleSecondaryTextStyle: Color {
        isUser ? .white.opacity(0.7) : .secondary
    }

    private var imagePreview: some View {
        ZStack {
            theme.terminalCardFill
            imagePreviewContent
        }
        .frame(width: previewSize.width, height: previewSize.height)
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
            pixelHeight: attachment.pixelHeight,
            aspectRatio: attachment.aspectRatio
        )
    }

    private var previewSize: CGSize {
        let resolvedMaxWidth = bubbleMaxWidth.isFinite && bubbleMaxWidth > 0 ? bubbleMaxWidth : 320
        return previewLayout.size(maxWidth: resolvedMaxWidth)
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

    private var currentThumbnailTaskID: ChatAttachmentThumbnailTaskID? {
        guard let request = currentThumbnailRequest else { return nil }
        return ChatAttachmentThumbnailTaskID(
            request: request,
            retryAttempt: thumbnailRetryAttempt
        )
    }

    /// Trailing-side grouped-corner shape matching the prose bubble rules.
    private var bubbleShape: UnevenRoundedRectangle {
        let full = theme.bubbleCornerRadius
        let tight = theme.bubbleGroupedCornerRadius
        let tightTop = groupPosition == .middle || groupPosition == .last
        let tightBottom = groupPosition == .first || groupPosition == .middle
        if !isUser {
            return UnevenRoundedRectangle(
                topLeadingRadius: tightTop ? tight : full,
                bottomLeadingRadius: tightBottom ? tight : full,
                bottomTrailingRadius: full,
                topTrailingRadius: full
            )
        }
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

    private func loadThumbnail(taskID: ChatAttachmentThumbnailTaskID) async {
        let request = taskID.request
        if thumbnailRequest != request {
            thumbnailRequest = request
            thumbnailData = nil
            thumbnailFailed = false
            thumbnailRetryAttempt = 0
        }
        guard thumbnailRetryAttempt == taskID.retryAttempt else { return }
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
            guard let delay = ChatAttachmentThumbnailRetryPolicy.delayNanoseconds(
                forAttempt: taskID.retryAttempt
            ) else {
                thumbnailFailed = true
                return
            }
            thumbnailFailed = false
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled,
                  thumbnailRequest == request,
                  thumbnailData == nil,
                  thumbnailRetryAttempt == taskID.retryAttempt else { return }
            thumbnailRetryAttempt = taskID.retryAttempt + 1
        }
    }
}

private struct ChatAttachmentThumbnailRequest: Hashable {
    let path: String
    let scope: ChatArtifactLoaderScope
    let supportsArtifacts: Bool
    let byteCount: Int64?
}

private struct ChatAttachmentThumbnailTaskID: Hashable {
    let request: ChatAttachmentThumbnailRequest
    let retryAttempt: Int
}

enum ChatAttachmentThumbnailRetryPolicy {
    private static let delaysInMilliseconds: [UInt64] = [250, 600, 1_200, 2_400]

    static func delayNanoseconds(forAttempt attempt: Int) -> UInt64? {
        guard delaysInMilliseconds.indices.contains(attempt) else { return nil }
        return delaysInMilliseconds[attempt] * 1_000_000
    }
}
