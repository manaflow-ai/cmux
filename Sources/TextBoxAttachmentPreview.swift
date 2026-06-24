import AppKit
import SwiftUI

private enum TextBoxAttachmentPreviewLayout {
    static let maxImageSize = CGSize(width: 408, height: 288)
    static let minImageSize = CGSize(width: 220, height: 140)
    static let cornerRadius: CGFloat = 14
    static let topButtonPadding: CGFloat = 8
    static let previewPadding: CGFloat = 8
    static let buttonTrailingPadding: CGFloat = 8
}

private struct TextBoxAttachmentPreviewMetrics {
    let imageSize: CGSize
    let contentSize: NSSize

    static func metrics(for attachment: TextBoxAttachment) -> TextBoxAttachmentPreviewMetrics {
        let imageSize = fittedImageSize(for: attachment)
        let padding = TextBoxAttachmentPreviewLayout.previewPadding
        return TextBoxAttachmentPreviewMetrics(
            imageSize: imageSize,
            contentSize: NSSize(
                width: imageSize.width + padding * 2,
                height: imageSize.height + padding * 2
            )
        )
    }

    private static func fittedImageSize(for attachment: TextBoxAttachment) -> CGSize {
        let fallback = CGSize(width: 260, height: 160)
        guard let image = attachment.thumbnail else { return fallback }

        let natural = naturalSize(for: image)
        guard natural.width > 0, natural.height > 0 else { return fallback }

        let minSize = TextBoxAttachmentPreviewLayout.minImageSize
        let maxSize = TextBoxAttachmentPreviewLayout.maxImageSize
        let maxScale = min(maxSize.width / natural.width, maxSize.height / natural.height)
        let needsMinimumSize = natural.width < minSize.width || natural.height < minSize.height
        let scale: CGFloat
        if needsMinimumSize {
            let minScale = max(minSize.width / natural.width, minSize.height / natural.height)
            scale = min(minScale, maxScale)
        } else {
            scale = min(1, maxScale)
        }
        return CGSize(
            width: max(1, floor(natural.width * scale)),
            height: max(1, floor(natural.height * scale))
        )
    }

    private static func naturalSize(for image: NSImage) -> CGSize {
        if let rep = image.representations.max(by: { lhs, rhs in
            lhs.pixelsWide * lhs.pixelsHigh < rhs.pixelsWide * rhs.pixelsHigh
        }), rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return image.size
    }
}

struct TextBoxAttachmentPreviewPopoverView: View {
    let attachment: TextBoxAttachment
    let imageSize: CGSize

    @State private var isPresented = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            previewContent
                .frame(width: imageSize.width, height: imageSize.height)
                .padding(TextBoxAttachmentPreviewLayout.previewPadding)

            if attachment.localURL != nil {
                Button(action: openInPreview) {
                    Text(String(localized: "textbox.openWithPreview.button", defaultValue: "Open with Preview"))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                .buttonStyle(TextBoxAttachmentPreviewOpenButtonStyle())
                .help(String(localized: "textbox.openInPreview.tooltip", defaultValue: "Open in Preview"))
                .accessibilityLabel(String(localized: "textbox.openInPreview.tooltip", defaultValue: "Open in Preview"))
                .padding(.top, TextBoxAttachmentPreviewLayout.topButtonPadding)
                .padding(.trailing, TextBoxAttachmentPreviewLayout.buttonTrailingPadding)
            }
        }
        .frame(
            width: imageSize.width + TextBoxAttachmentPreviewLayout.previewPadding * 2,
            height: imageSize.height + TextBoxAttachmentPreviewLayout.previewPadding * 2
        )
        .clipShape(RoundedRectangle(cornerRadius: TextBoxAttachmentPreviewLayout.cornerRadius, style: .continuous))
        .background(Color.black.clipShape(RoundedRectangle(cornerRadius: TextBoxAttachmentPreviewLayout.cornerRadius, style: .continuous)))
        .overlay {
            RoundedRectangle(cornerRadius: TextBoxAttachmentPreviewLayout.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 20, y: 8)
        .scaleEffect(isPresented ? 1 : 0.96, anchor: .bottom)
        .opacity(isPresented ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                isPresented = true
            }
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        if let thumbnail = attachment.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFit()
                .frame(width: imageSize.width, height: imageSize.height)
                .background(Color.black.opacity(0.82))
        } else {
            VStack(spacing: 10) {
                Image(systemName: "doc")
                    .font(.system(size: 42, weight: .regular))
                Text(attachment.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.primary.opacity(0.86))
            .frame(width: imageSize.width, height: imageSize.height)
        }
    }

    private func openInPreview() {
        TextBoxAttachmentPreviewOpening.openInPreview(attachment)
    }
}

@MainActor
enum TextBoxAttachmentPreviewOpening {
    static func openInPreview(_ attachment: TextBoxAttachment) {
        guard let url = attachment.localURL else { return }
        if let previewURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: previewURL, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct TextBoxAttachmentPreviewOpenButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.78 : 0.94))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.28 : 0.22))
            }
            .contentShape(Capsule(style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

final class TextBoxAttachmentPreviewController: NSHostingController<TextBoxAttachmentPreviewPopoverView> {

    init(attachment: TextBoxAttachment) {
        let metrics = TextBoxAttachmentPreviewMetrics.metrics(for: attachment)
        super.init(rootView: TextBoxAttachmentPreviewPopoverView(
            attachment: attachment,
            imageSize: metrics.imageSize
        ))
        preferredContentSize = metrics.contentSize
    }

    @available(*, unavailable)
    @MainActor
    dynamic required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
