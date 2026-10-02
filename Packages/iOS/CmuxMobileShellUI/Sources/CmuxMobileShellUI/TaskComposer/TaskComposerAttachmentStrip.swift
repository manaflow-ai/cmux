#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Shared horizontal strip of staged New Task attachments.
struct TaskComposerAttachmentStrip: View {
    let attachments: [TaskComposerAttachment]
    let isDisabled: Bool
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(attachments) { attachment in
                    chip(for: attachment)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(attachment.displayName)
                        .accessibilityAction(
                            named: L10n.string(
                                "mobile.taskComposer.attachments.remove",
                                defaultValue: "Remove Attachment"
                            )
                        ) {
                            remove(attachment.id)
                        }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func chip(for attachment: TaskComposerAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            switch attachment.kind {
            case .image:
                imageChip(attachment)
            case .file:
                fileChip(attachment)
            }

            Button {
                remove(attachment.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.65))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel(L10n.string(
                "mobile.taskComposer.attachments.remove",
                defaultValue: "Remove Attachment"
            ))
            .offset(x: 5, y: -5)
        }
        .padding(.top, 5)
        .padding(.trailing, 5)
    }

    private func imageChip(_ attachment: TaskComposerAttachment) -> some View {
        Group {
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

    private func fileChip(_ attachment: TaskComposerAttachment) -> some View {
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
