#if os(iOS)
import AVFoundation
import CmuxMobileTransport
import PhotosUI
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The composer row (SPEC 4.3 collapsed metrics, 10.2): `+` menu (Photos,
/// Files, Paste), a growing text field and the send button, which sends the
/// text plus Return, or a bare Return when the field is empty.
struct TerminalComposer: View {
    @Bindable var model: TerminalModel
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isScrolledUp {
                // In the card, not over the rows: a floating button hid the
                // end of the lines under it (Codex QA F3).
                Button {
                    model.scrollToBottom()
                } label: {
                    Label("Jump to bottom", systemImage: "arrow.down")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Color.primary.opacity(0.08), in: .capsule)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("Scroll to bottom")
                .transition(.opacity)
            }
            if let notice = model.composerNotice {
                Label(notice, systemImage: "exclamationmark.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .accessibilityIdentifier("terminal.composer.notSent")
            }
            if let error = model.attachmentError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .accessibilityIdentifier("terminal.composer.attachmentError")
            }
            if !model.attachments.isEmpty {
                AttachmentStrip(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            HStack(alignment: .bottom, spacing: 6) {
                if model.attachmentsAvailable { plusMenu }
                field
                sendButton
            }
        }
        .padding(6)
        // The glass sits on 85 % of the terminal background, so rows that
        // scroll under the composer are not legible through it (SPEC M3).
        .background(Color(uiColor: CmuxMobileGhosttyApp.background).opacity(0.85), in: .rect(cornerRadius: 24, style: .continuous))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 8)
        // V6-1: a draft that shrinks (6 lines to 5) drew a shorter card while
        // the hosting view kept the taller height, so the page's bottom inset
        // (and the last row) stayed 6-11 pt above the card. The card's own
        // height tells the screen to measure the composer again.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            model.controller?.composerCardHeightChanged(height)
        }
        .animation(.smooth(duration: 0.3), value: model.attachments.count)
        .onChange(of: model.composerText) { _, _ in model.composerEdited() }
        // Shown with a fade; gone at once when following starts (a Jump to
        // bottom tap: qa11 wt-fling-c, the row still drawn after the page
        // reached the bottom, and the card shrinking over 0.2 s moved the
        // page's inset on every frame of the jump).
        .animation(model.isScrolledUp ? .smooth(duration: 0.2) : nil, value: model.isScrolledUp)
        .photosPicker(isPresented: $model.showPhotoPicker, selection: $photoItems, maxSelectionCount: 6,
                      matching: .any(of: [.images, .videos]), preferredItemEncoding: .compatible)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await loadPhotos(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            TerminalCameraPicker { image in
                guard let data = image.jpegData(compressionQuality: 0.85) else { return }
                model.addAttachment(ComposerAttachment(kind: .image, name: "Camera \(Self.stamp()).jpg",
                                                       thumbnail: image.preparingThumbnail(of: CGSize(width: 168, height: 168)), data: data))
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $model.showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await loadFiles(urls) }
        }
    }

    private var plusMenu: some View {
        // ChatGPT's order: Camera, Photos, Files. Paste leads only when the
        // pasteboard holds an image or a file (SPEC P9).
        // Paste is offered only for an image or a file (text pastes into the
        // field itself), and then first (R1-8). Reading the types does not
        // trigger the paste prompt.
        let pasteFirst = ComposerPasteRoute.offersPaste(
            hasImage: UIPasteboard.general.hasImages,
            hasFileURL: UIPasteboard.general.contains(pasteboardTypes: [UTType.fileURL.identifier]))
        return Menu {
            if pasteFirst {
                Section { pasteButton }
            }
            Section {
                if TerminalCameraPicker.isAvailable {
                    Button("Camera", systemImage: "camera") { showCamera = true }
                } else {
                    Button {} label: {
                        Label("Camera", systemImage: "camera")
                        Text("No camera on this device")
                    }
                    .disabled(true)
                }
                Button("Photos", systemImage: "photo.on.rectangle") { model.showPhotoPicker = true }
                Button("Files", systemImage: "folder") { model.showFileImporter = true }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .medium))
                .frame(width: 36, height: 36)
                .background(Color.primary.opacity(0.08), in: .circle)
                .contentShape(.circle)
        }
        .tint(.primary)
        .accessibilityLabel("Add attachment")
    }

    private var pasteButton: some View {
        Button("Paste", systemImage: "doc.on.clipboard") { pasteFromClipboard() }
    }

    private var field: some View {
        HStack(spacing: 6) {
            if model.directTyping {
                Image(systemName: "keyboard")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            ComposerTextView(
                text: $model.composerText,
                placeholder: model.composerPlaceholder,
                focusRequest: model.composerFocusRequest,
                focusOnAppear: model.composerFocusOnAppear,
                onFocusChange: { isFocused in
                    model.composerFocused = isFocused
                    if isFocused { model.composerFocusOnAppear = false }
                    if isFocused { model.directTyping = false }
                    model.controller?.inputFocusChanged()
                },
                onReturn: { model.send() },
                shouldInsert: { model.composerShouldInsert($0) }
            )
        }
        .padding(.leading, 4)
        .frame(minHeight: 36)
    }

    private var sendButton: some View {
        let empty = model.composerText.isEmpty && model.attachments.isEmpty
        return Button {
            model.send()
        } label: {
            ZStack {
                if model.isUploading {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: empty ? "return" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(empty ? Color.primary : Color.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 36, height: 36)
            // ↑ (send) is the primary action: accent fill, like the agent composer (SPEC P11).
            .background(empty ? AnyShapeStyle(Color.primary.opacity(0.08)) : AnyShapeStyle(Color(uiColor: .systemBlue)), in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(model.isUploading)
        .contextMenu {
            Button("Send without Return", systemImage: "arrow.up.to.line") { model.sendWithoutReturn() }
        }
        .accessibilityLabel(empty ? "Return" : "Send")
        .accessibilityIdentifier("terminal.composer.send")
    }

    /// An image or a copied file becomes an attachment (uploaded to the Mac on
    /// send, its Mac path typed: the same path as Files); text goes into the
    /// field; a phone `file:///` path is never typed (R2-2).
    private func pasteFromClipboard() {
        let board = UIPasteboard.general
        let route = ComposerPasteRoute.route(hasImage: board.hasImages, fileURL: board.hasURLs ? board.url : nil,
                                             string: board.hasStrings ? board.string : nil)
        switch route {
        case .image:
            guard let image = board.image, let data = image.pngData() else { return }
            model.addAttachment(ComposerAttachment(kind: .image, name: "Pasted image \(Self.stamp()).png",
                                                   thumbnail: image.preparingThumbnail(of: CGSize(width: 168, height: 168)), data: data))
        case .file(let url):
            Task { await loadFiles([url]) }
        case .text(let text):
            model.composerText += text
        case .nothing:
            break
        }
    }

    // MARK: Loading attachments

    /// Picked photos and videos keep their bytes (a video its local copy).
    /// Photos has no file name for an item without library access, so the
    /// name says what it is and when it was attached.
    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        let stamp = Self.stamp()
        for (index, item) in items.enumerated() {
            let suffix = items.count > 1 ? " \(index + 1)" : ""
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            if isVideo, let movie = try? await item.loadTransferable(type: MovieFile.self) {
                let thumbnail = await Self.videoThumbnail(movie.url)
                let size = (try? movie.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                let ext = movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension
                model.addAttachment(ComposerAttachment(kind: .video, name: "Video \(stamp)\(suffix).\(ext)", thumbnail: thumbnail,
                                                       byteCount: size, fileURL: movie.url))
            } else if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                let thumbnail = await image.byPreparingThumbnail(ofSize: CGSize(width: 168, height: 168))
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                model.addAttachment(ComposerAttachment(kind: .image, name: "Photo \(stamp)\(suffix).\(ext)", thumbnail: thumbnail, data: data))
            }
        }
    }

    /// Files are read now, while the picker's security scope is open.
    private func loadFiles(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 56, height: 56), scale: 3, representationTypes: .thumbnail)
            let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
            let kind: ComposerAttachment.Kind = type.conforms(to: .image) ? .image : type.conforms(to: .movie) ? .video : .file
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard size <= LinkUpload.maxBytes else {
                model.attachmentError = "\(url.lastPathComponent) is larger than \(LinkUpload.maxBytes >> 20) MB."
                continue
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                model.attachmentError = "Couldn't read \(url.lastPathComponent)."
                continue
            }
            model.addAttachment(ComposerAttachment(kind: kind, name: url.lastPathComponent, thumbnail: thumbnail, data: data))
        }
    }

    static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter.string(from: date)
    }

    static func videoThumbnail(_ url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 168, height: 168)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: image)
    }
}

/// A picked movie, copied out of the Photos sandbox.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(received.file.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }
}

/// Inline previews: 56 x 56 thumbnails (radius 12) for photos and videos, 56 h
/// chips for files, each with a 20 pt remove badge.
struct AttachmentStrip: View {
    let model: TerminalModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(model.attachments) { attachment in
                    tile(attachment)
                        .contentShape(.rect(cornerRadius: 12, style: .continuous))
                        // Tap opens it full screen before it is sent.
                        .onTapGesture { model.previewAttachment(attachment.id) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Opens a preview")
                        .accessibilityIdentifier("terminal.attachment")
                        .overlay(alignment: .topTrailing) {
                            Button {
                                model.removeAttachment(attachment.id)
                            } label: {
                                // Opaque, ringed badge (as in Messages): readable over any thumbnail.
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 22, height: 22)
                                    .background(Color(white: 0.18), in: .circle)
                                    .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.5))
                                    .frame(width: 44, height: 44)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 16, y: -16)
                            .accessibilityLabel("Remove \(attachment.name)")
                        }
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private func tile(_ attachment: ComposerAttachment) -> some View {
        switch attachment.kind {
        case .image, .video:
            ZStack {
                if let thumbnail = attachment.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.primary.opacity(0.08)
                    Image(systemName: attachment.kind == .video ? "video" : "photo").foregroundStyle(.secondary)
                }
                if attachment.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .accessibilityLabel(attachment.name)
        case .file:
            HStack(spacing: 8) {
                Group {
                    if let thumbnail = attachment.thumbnail {
                        Image(uiImage: thumbnail).resizable().scaledToFit()
                    } else {
                        Image(systemName: "doc.text").font(.system(size: 20)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 32, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name).font(.footnote.weight(.medium)).lineLimit(1)
                    if let bytes = attachment.byteCount {
                        Text(Int64(bytes), format: .byteCount(style: .file)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 140, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(height: 56)
            .background(Color.primary.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
        }
    }
}
#endif

#if os(iOS)
/// UIImagePickerController's camera for the composer's Camera item (SwiftUI has no camera picker).
struct TerminalCameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: TerminalCameraPicker
        init(_ parent: TerminalCameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
#endif
