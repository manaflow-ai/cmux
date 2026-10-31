#if os(iOS)
import AVFoundation
import CmuxMobileDesign
import CmuxMobileSupport
import CmuxMobileTransport
import PhotosUI
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The composer row (classic cmux iOS's terminal composer): a paperclip
/// menu (Photo Library, Choose Files, Paste, Camera) and a mic in 40 pt glass
/// circles, then the growing field in a rounded glass container with the send
/// circle inside it, riding the last line. Send delivers the draft as one
/// paste plus Return (`ComposerSubmit`); Return in the field starts a new line.
/// It sits below the key row, nearest the keyboard, and is open by default.
struct TerminalComposer: View {
    @Bindable var model: TerminalModel
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    /// On-device dictation into the field (classic's controller, shared).
    /// Owned here so it never outlives the composer: it stops on send, on
    /// focus loss and when the composer goes away.
    @State private var dictation = ComposerDictationController()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.isScrolledUp {
                // In the stack, not over the rows: a floating button hid the
                // end of the lines under it (Codex QA F3).
                Button {
                    model.scrollToBottom()
                } label: {
                    Label("Jump to bottom", systemImage: "arrow.down")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .glassSurface(in: .rect(cornerRadius: KeyRowGlass.cornerRadius, style: .continuous))
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
                    .padding(.leading, TerminalDockMetrics.control + 8)
                    .accessibilityIdentifier("terminal.composer.notSent")
            }
            if let error = model.attachmentError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.leading, TerminalDockMetrics.control + 8)
                    .accessibilityIdentifier("terminal.composer.attachmentError")
            }
            if !model.attachments.isEmpty {
                AttachmentStrip(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            GlassEffectContainer(spacing: 0) {
                HStack(alignment: .bottom, spacing: 8) {
                    if model.attachmentsAvailable { attachMenu }
                    micButton
                    fieldContainer
                }
            }
        }
        .padding(.horizontal, TerminalDockMetrics.horizontalInset)
        // V6-1: a draft that shrinks drew a shorter row while the hosting view
        // kept the taller height. The row's own height tells the screen to
        // measure the composer again (classic: the band reflows over 0.25 s).
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            model.controller?.composerCardHeightChanged(height)
        }
        .animation(.smooth(duration: 0.3), value: model.attachments.count)
        .onChange(of: model.composerText) { _, _ in model.composerEdited() }
        .onChange(of: model.composerFocused) { _, focused in
            // The person moved on: keep what was said (a graceful stop), unless
            // dictation's own field lock took the focus.
            if !focused, !dictation.locksComposerField { dictation.stop() }
        }
        .onDisappear { dictation.cancel() }
        // Closing the composer or Hide Toolbar only hides this view, so it
        // never disappears: the mic stops here instead.
        .onChange(of: model.composerPresented && !model.chromeHidden) { _, shown in
            if !shown { dictation.cancel() }
        }
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

    /// Classic's order: Photo Library, Choose Files, Paste; then Camera,
    /// which cmux NEXT offers as well.
    private var attachMenu: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { model.showPhotoPicker = true }
            Button("Choose Files", systemImage: "folder") { model.showFileImporter = true }
            Button("Paste", systemImage: "doc.on.clipboard") { pasteFromClipboard() }
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
            }
        } label: {
            ComposerCircleLabel(systemImage: "paperclip")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Attachment")
        .accessibilityIdentifier("terminal.composer.attach")
    }

    /// The mic: on-device dictation into the field (classic). Listening, it
    /// is a pulsing red filled mic and the field is locked so a typed edit is
    /// never overwritten by the next result.
    private var micButton: some View {
        let listening = dictation.state.isListening
        return Button {
            dictation.toggle(existingText: model.composerText) { merged in
                model.composerText = merged
            }
        } label: {
            ComposerCircleLabel(systemImage: listening ? "mic.fill" : "mic",
                                foreground: listening ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.primary.opacity(0.78)))
                .symbolEffect(.pulse, isActive: listening)
        }
        .buttonStyle(.plain)
        .disabled(!dictation.isAvailable)
        .accessibilityLabel(listening ? "Stop dictation" : "Start dictation")
        .accessibilityIdentifier("terminal.composer.mic")
    }

    /// The field and its send circle share one rounded glass container; the
    /// circle rides the last line as the field grows (classic, iMessage).
    private var fieldContainer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ComposerTextView(
                text: $model.composerText,
                placeholder: model.composerPlaceholder,
                focusRequest: model.composerFocusRequest,
                focusOnAppear: model.composerFocusOnAppear,
                isDisabled: dictation.locksComposerField,
                onFocusChange: { isFocused in
                    model.composerFocused = isFocused
                    if isFocused { model.composerFocusOnAppear = false }
                    if isFocused { model.directTyping = false }
                    model.controller?.inputFocusChanged()
                },
                onReturn: { send() },
                shouldInsert: { model.composerShouldInsert($0) },
                onPasteAttachments: model.attachmentsAvailable ? { pasteFromClipboard() } : nil
            )
            sendButton
        }
        .padding(.leading, 14)
        .padding(.trailing, TerminalDockMetrics.fieldPadding)
        .padding(.vertical, TerminalDockMetrics.fieldPadding)
        .frame(minHeight: TerminalDockMetrics.control, alignment: .top)
        .glassSurface(in: .rect(cornerRadius: TerminalDockMetrics.fieldCornerRadius, style: .continuous))
    }

    private var sendButton: some View {
        let canSend = !(model.composerText.isEmpty && model.attachments.isEmpty)
        let failed = model.attachmentError != nil
        return Button {
            send()
        } label: {
            ZStack {
                if model.isUploading {
                    ProgressView().controlSize(.small).tint(Color.cmuxMobileOnAccent)
                } else {
                    Image(systemName: failed ? "exclamationmark" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(failed ? AnyShapeStyle(Color.white) : canSend ? AnyShapeStyle(Color.cmuxMobileOnAccent) : AnyShapeStyle(Color.primary.opacity(0.35)))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: TerminalDockMetrics.sendDiameter, height: TerminalDockMetrics.sendDiameter)
            // ↑ (send) is the primary action: glass tinted with the
            // monochrome accent, never blue (design/ios.md); empty, plain glass.
            // Empty (disabled): plain glass that does not react to a touch.
            .glassEffect(failed ? .regular.tint(.red).interactive()
                         : canSend || model.isUploading ? .regular.tint(Color.cmuxMobileAccent).interactive()
                         : .regular, in: .circle)
            .animation(.smooth(duration: 0.2), value: canSend)
        }
        .buttonStyle(.plain)
        .disabled(model.isUploading || !canSend)
        .contextMenu {
            Button("Send without Return", systemImage: "arrow.up.to.line") {
                dictation.cancel()
                model.sendWithoutReturn()
            }
        }
        .accessibilityLabel(model.isUploading ? "Sending" : failed ? "Send failed" : "Send")
        .accessibilityIdentifier("terminal.composer.send")
    }

    /// Dictation stops before a send, so the draft sent is the field's text
    /// now and no late result writes into the cleared field (classic).
    private func send() {
        dictation.cancel()
        model.send()
    }

    /// An image or a copied file becomes an attachment (uploaded to the Mac on
    /// send, its Mac path typed: the same path as Files); text goes into the
    /// field; a phone `file:///` path is never typed (R2-2). Reading the
    /// pasteboard here is the person's own tap on Paste.
    private func pasteFromClipboard() {
        let board = UIPasteboard.general
        // A file copied in Files is its bytes on the pasteboard, not a path.
        if board.composerHoldsFileData {
            let providers = board.itemProviders
            Task { await loadPastedFiles(providers) }
            return
        }
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

    /// Copied files, as Files would attach them (uploaded on send).
    private func loadPastedFiles(_ providers: [NSItemProvider]) async {
        let pasted = await ComposerPastedFiles.load(providers)
        if let name = pasted.unreadable.first { model.attachmentError = "Couldn't read \(name)." }
        for file in pasted.files {
            let image = file.type.conforms(to: .image) ? file.data.flatMap { UIImage(data: $0) } : nil
            let kind: ComposerAttachment.Kind = image != nil ? .image : file.type.conforms(to: .movie) ? .video : .file
            model.addAttachment(ComposerAttachment(kind: kind, name: file.name,
                                                   thumbnail: image?.preparingThumbnail(of: CGSize(width: 168, height: 168)), byteCount: file.byteCount, data: file.data, fileURL: file.fileURL))
        }
    }

    /// Files of any size keep their URL, and each later reader reopens the
    /// picker's security scope (`ScopedFile`): the preview while it is open,
    /// the upload while it streams. The thumbnail and size are read now, in scope.
    private func loadFiles(_ urls: [URL]) async {
        for url in urls {
            let access = ScopedFile(url).open()
            defer { access.close() }
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 56, height: 56), scale: 3, representationTypes: .thumbnail)
            let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
            let kind: ComposerAttachment.Kind = type.conforms(to: .image) ? .image : type.conforms(to: .movie) ? .video : .file
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
                model.attachmentError = "Couldn't read \(url.lastPathComponent)."
                continue
            }
            model.addAttachment(ComposerAttachment(kind: kind, name: url.lastPathComponent, thumbnail: thumbnail,
                                                   byteCount: size, fileURL: url))
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

/// A 40 pt glass circle with an icon: the composer's paperclip and mic (classic).
struct ComposerCircleLabel: View {
    let systemImage: String
    var foreground = AnyShapeStyle(Color.primary.opacity(0.78))

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: TerminalDockMetrics.control, height: TerminalDockMetrics.control)
            .glassSurface(in: .circle)
            .contentShape(.circle)
    }
}

extension View {
    /// The composer's Liquid Glass (classic: the field container and the
    /// round buttons). No opaque backing: the screen's own backing under the
    /// dock keeps scrolled rows from showing through (SPEC M3).
    func glassSurface(in shape: some Shape) -> some View {
        glassEffect(.regular.interactive(), in: shape)
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
                                    // Glass, darkened so it reads over any thumbnail (as in Messages).
                                    .glassEffect(.regular.tint(.black.opacity(0.5)).interactive(), in: .circle)
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
            .glassSurface(in: .rect(cornerRadius: 12, style: .continuous))
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
