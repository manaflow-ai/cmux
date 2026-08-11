#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Shared horizontal strip of staged New Task attachments.
struct TaskComposerAttachmentStrip: View {
    @State private var previewedAttachment: TaskComposerAttachment?

    let attachments: [TaskComposerAttachment]
    let isDisabled: Bool
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(attachments) { attachment in
                    TaskComposerAttachmentChip(
                        attachment: attachment,
                        isRemoveDisabled: isDisabled,
                        preview: { previewedAttachment = attachment },
                        remove: { remove(attachment.id) }
                    )
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .sheet(item: $previewedAttachment) { attachment in
            TaskComposerAttachmentPreview(attachment: attachment)
        }
    }
}

/// One stable, independently accessible attachment row item. The primary
/// action previews the staged bytes; removal remains a separate edge action.
private struct TaskComposerAttachmentChip: View {
    let attachment: TaskComposerAttachment
    let isRemoveDisabled: Bool
    let preview: () -> Void
    let remove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: preview) {
                TaskComposerAttachmentChipContent(attachment: attachment)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(attachment.displayName)
            .accessibilityHint(L10n.string(
                "mobile.taskComposer.attachments.preview",
                defaultValue: "Preview Attachment"
            ))
            .accessibilityIdentifier(
                "MobileTaskComposerAttachmentPreview-\(attachment.id.uuidString)"
            )
            .accessibilityAction(named: L10n.string(
                "mobile.taskComposer.attachments.remove",
                defaultValue: "Remove Attachment"
            )) {
                remove()
            }

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(isRemoveDisabled)
            .accessibilityLabel(L10n.string(
                "mobile.taskComposer.attachments.remove",
                defaultValue: "Remove Attachment"
            ))
            .offset(x: 5, y: -5)
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
    }
}

/// Narrow rendering boundary for one staged attachment's visual content.
private struct TaskComposerAttachmentChipContent: View {
    let attachment: TaskComposerAttachment

    var body: some View {
        ZStack {
            switch attachment.kind {
            case .image:
                imageContent
            case .file:
                fileContent
            }
        }
    }

    private var imageContent: some View {
        ZStack {
            if let thumbnailData = attachment.thumbnailData,
               let image = UIImage(data: thumbnailData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 56, height: 56)
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var fileContent: some View {
        HStack(spacing: 7) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
            Text(attachment.displayName)
                .font(.subheadline)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .frame(maxWidth: 190)
        .background(
            Color.primary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}
#endif
