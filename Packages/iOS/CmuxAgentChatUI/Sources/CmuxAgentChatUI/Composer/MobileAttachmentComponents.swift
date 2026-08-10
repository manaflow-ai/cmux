#if os(iOS)
import CmuxMobileSupport
import PhotosUI
import QuickLook
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// File-backed Photos transfer that avoids loading full-resolution bytes into memory.
public struct MobileImportedImageFile: Transferable, Sendable {
    public let url: URL
    public let originalFileName: String

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { value in
            SentTransferredFile(value.url)
        } importing: { received in
            let suffix = received.file.pathExtension.isEmpty ? "" : ".\(received.file.pathExtension)"
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-photo-import-\(UUID())\(suffix)")
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination, originalFileName: received.file.lastPathComponent)
        }
    }
}

/// The shared attachment source menu used by every iOS composer.
public struct MobileAttachmentPickerButton: View {
    public enum Style { case circularPlus, paperclip }

    private let style: Style
    private let isDisabled: Bool
    private let choosePhotos: () -> Void
    private let chooseFiles: () -> Void

    public init(
        style: Style = .paperclip,
        isDisabled: Bool,
        choosePhotos: @escaping () -> Void,
        chooseFiles: @escaping () -> Void
    ) {
        self.style = style
        self.isDisabled = isDisabled
        self.choosePhotos = choosePhotos
        self.chooseFiles = chooseFiles
    }

    public var body: some View {
        Menu {
            Button(action: choosePhotos) {
                Label(localized("mobile.attachment.photos", "Photos"), systemImage: "photo.on.rectangle")
            }
            Button(action: chooseFiles) {
                Label(localized("mobile.attachment.files", "Files"), systemImage: "folder")
            }
        } label: {
            Image(systemName: style == .circularPlus ? "plus" : "paperclip")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(style == .circularPlus ? Color.primary.opacity(0.07) : .clear, in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(localized("mobile.attachment.add", "Add Attachment"))
        .accessibilityIdentifier("MobileAttachmentPickerButton")
    }
}

/// Hosts Photos and Files pickers while keeping their trigger anchored to one menu.
public struct MobileAttachmentPickerModifier: ViewModifier {
    @Binding private var isPhotoPickerPresented: Bool
    @Binding private var photoSelection: [PhotosPickerItem]
    @Binding private var isFileImporterPresented: Bool
    private let remainingCount: Int
    private let selectedPhotos: ([PhotosPickerItem]) -> Void
    private let selectedFiles: (Result<[URL], any Error>) -> Void

    public init(
        isPhotoPickerPresented: Binding<Bool>,
        photoSelection: Binding<[PhotosPickerItem]>,
        isFileImporterPresented: Binding<Bool>,
        remainingCount: Int,
        selectedPhotos: @escaping ([PhotosPickerItem]) -> Void,
        selectedFiles: @escaping (Result<[URL], any Error>) -> Void
    ) {
        _isPhotoPickerPresented = isPhotoPickerPresented
        _photoSelection = photoSelection
        _isFileImporterPresented = isFileImporterPresented
        self.remainingCount = remainingCount
        self.selectedPhotos = selectedPhotos
        self.selectedFiles = selectedFiles
    }

    public func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $photoSelection,
                maxSelectionCount: max(remainingCount, 1),
                selectionBehavior: .ordered,
                matching: .images
            )
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true,
                onCompletion: selectedFiles
            )
            .onChange(of: photoSelection) { _, items in
                guard !items.isEmpty else { return }
                photoSelection = []
                selectedPhotos(items)
            }
    }
}

/// Shared image/file card strip with preview and a distinct remove control.
public struct MobileAttachmentCardStrip: View {
    private let attachments: [MobileStagedAttachment]
    private let isDisabled: Bool
    private let isPreparing: Bool
    private let progress: [UUID: Double]
    private let remove: (UUID) -> Void
    private let onPreviewDismiss: () -> Void
    @State private var preview: MobileStagedAttachment?
    @ScaledMetric(relativeTo: .caption) private var cardHeight: CGFloat = 72
    @ScaledMetric(relativeTo: .caption) private var fileCardWidth: CGFloat = 176

    public init(
        attachments: [MobileStagedAttachment],
        isDisabled: Bool,
        isPreparing: Bool = false,
        progress: [UUID: Double] = [:],
        onPreviewDismiss: @escaping () -> Void = {},
        remove: @escaping (UUID) -> Void
    ) {
        self.attachments = attachments
        self.isDisabled = isDisabled
        self.isPreparing = isPreparing
        self.progress = progress
        self.onPreviewDismiss = onPreviewDismiss
        self.remove = remove
    }

    public var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                    card(attachment, index: index)
                }
                if isPreparing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(localized("mobile.attachment.preparing", "Preparing…"))
                            .font(.subheadline)
                    }
                    .padding(12)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(localized("mobile.attachment.preparing", "Preparing…"))
                    .accessibilityIdentifier("MobileAttachmentPreparing")
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.hidden)
        .sheet(item: $preview, onDismiss: onPreviewDismiss) {
            MobileAttachmentPreview(attachment: $0)
        }
        .accessibilityIdentifier("MobileAttachmentCardStrip")
    }

    private func card(_ attachment: MobileStagedAttachment, index: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            Button { preview = attachment } label: {
                Group {
                    if attachment.kind == .image {
                        imageCard(attachment)
                    } else {
                        fileCard(attachment)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let value = progress[attachment.id] {
                        ProgressView(value: value)
                            .tint(.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)
                            .accessibilityValue(Text(value, format: .percent))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(
                format: localized("mobile.attachment.preview.named", "Preview %@"),
                attachment.fileName
            ))
            .accessibilityIdentifier("MobileAttachmentCard.\(index)")

            Button { remove(attachment.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.72))
                    .frame(width: 44, height: 44, alignment: .topTrailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .accessibilityLabel(String(
                format: localized("mobile.attachment.remove.named", "Remove %@"),
                attachment.fileName
            ))
            .accessibilityIdentifier("MobileAttachmentRemove.\(index)")
            .offset(x: 7, y: -7)
        }
        .padding(.top, 7)
        .padding(.trailing, 7)
    }

    @ViewBuilder
    private func imageCard(_ attachment: MobileStagedAttachment) -> some View {
        Group {
            if let data = attachment.thumbnailData,
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: cardHeight, height: cardHeight)
        .background(Color.primary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func fileCard(_ attachment: MobileStagedAttachment) -> some View {
        HStack(spacing: 9) {
            VStack(spacing: 2) {
                Image(systemName: "doc.fill")
                    .font(.title3)
                Text(fileExtension(for: attachment))
                    .font(.caption2.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(.secondary)
            .frame(width: 42, height: 52)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: fileCardWidth, height: cardHeight)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func fileExtension(for attachment: MobileStagedAttachment) -> String {
        let value = (attachment.fileName as NSString).pathExtension
        if value.isEmpty {
            return localized("mobile.attachment.file", "FILE")
        } else {
            return value.uppercased()
        }
    }
}

private struct MobileAttachmentPreview: View {
    @Environment(\.dismiss) private var dismiss
    let attachment: MobileStagedAttachment

    var body: some View {
        NavigationStack {
            Group {
                if QLPreviewController.canPreview(attachment.localFileURL as NSURL) {
                    QuickLookPreview(url: attachment.localFileURL)
                } else {
                    ContentUnavailableView(
                        localized("mobile.attachment.preview.unsupported.title", "Preview Unavailable"),
                        systemImage: "doc.questionmark",
                        description: Text(localized(
                            "mobile.attachment.preview.unsupported.message",
                            "This file type can’t be previewed."
                        ))
                    )
                }
            }
                .navigationTitle(attachment.fileName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(localized("mobile.attachment.done", "Done")) { dismiss() }
                    }
                }
        }
        .accessibilityIdentifier("MobileAttachmentPreview")
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

private func localized(_ key: String.LocalizationValue, _ fallback: String) -> String {
    String(localized: key, defaultValue: fallback, bundle: .module)
}
#endif
