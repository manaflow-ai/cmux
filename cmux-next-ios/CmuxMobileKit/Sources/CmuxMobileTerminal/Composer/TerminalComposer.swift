#if os(iOS)
import AVFoundation
import CmuxMobileDesign
import CmuxMobileRealtime
import CmuxMobileTransport
import CmuxSpinner
import PhotosUI
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// The composer row: one full-width rounded glass field that holds
/// everything (user, 2026-11-12: "thise buttons (clip and voice) will be
/// going inside the box"): the attachment tray on top, then the paperclip
/// menu (Photo Library, Choose Files, Paste, Camera), the growing text, voice
/// mode and the send circle on one row, the buttons riding the last line as
/// the field grows upward. Send delivers the draft as one paste plus Return
/// (`ComposerSubmit`); Return in the field starts a new line. It sits below
/// the key row, nearest the keyboard, and is open by default. Jump to bottom
/// is its own row above the key row (`TerminalJumpToBottomRow`).
struct TerminalComposer: View {
    @Bindable var model: TerminalModel
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    private let voice = AgentVoiceLauncher.shared

    private var voiceSource: (any AgentVoiceSource)? {
        guard let source = model.voiceSource, source.voiceAvailable, voice.isAvailable else { return nil }
        return source
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = model.composerNotice {
                Label(notice, systemImage: "exclamationmark.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.leading, 14)
                    .accessibilityIdentifier("terminal.composer.notSent")
            }
            if let line = model.connectionLine {
                // The connection's one quiet line, after 10 s of an outage; the
                // page keeps its last frame meanwhile (no pill over it).
                HStack(spacing: 6) {
                    Text(verbatim: line)
                    if let retry = model.reconnect {
                        Text(verbatim: "·").accessibilityHidden(true)
                        RetryButton(style: .inline, action: retry)
                            .accessibilityIdentifier("terminal.retry")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("terminal.connectionLine")
            }
            if let error = model.attachmentError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.leading, 14)
                    .accessibilityIdentifier("terminal.composer.attachmentError")
            }
            field
        }
        .padding(.horizontal, TerminalDockMetrics.horizontalInset)
        // Always its own height, never the hosting view's current one: offered
        // the old, shorter height, the field's min-height frame took it and
        // the grown draft and send circle ran out below the rounded field
        // (user report 2026-11-12), and since the row's height then never
        // changed, nothing asked the screen to grow it.
        .fixedSize(horizontal: false, vertical: true)
        // V6-1: a draft that shrinks drew a shorter row while the hosting view
        // kept the taller height. The row's own height tells the screen to
        // measure the composer again (classic: the band reflows over 0.25 s).
        // Measured here, on the card, before the frame below.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
            model.controller?.composerCardHeightChanged(height)
        }
        // Grows up from the keyboard: the frame takes the hosting view's
        // height, so until the view takes a taller card's height (the pass
        // after it is measured) the card overflows upward from the bottom
        // edge, never centered half below it over the keyboard (Leo,
        // 2026-11-12: "whoa it go down"). With no height offered (the
        // intrinsic size) the frame is the card's own height.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .bottom)
        .animation(.smooth(duration: 0.3).unlessReduceMotion, value: model.attachments.count)
        .onChange(of: model.composerText) { _, _ in model.composerEdited() }
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
            ComposerInlineCircle(systemImage: "paperclip")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Attachment")
        .accessibilityIdentifier("terminal.composer.attach")
    }

    /// Voice mode on this terminal's agent (replaces classic's dictation
    /// mic): its replies read aloud, the user's speech typed in as prompts.
    /// Filled and moving while it runs here; a tap ends it.
    private func voiceButton(_ source: any AgentVoiceSource) -> some View {
        let active = voice.isActive(source.voiceSourceID)
        return Button {
            voice.toggle(source)
        } label: {
            ComposerInlineCircle(systemImage: "waveform",
                                 foreground: active ? AnyShapeStyle(Color.cmuxMobileOnAccent) : AnyShapeStyle(Color.primary.opacity(0.78)),
                                 tint: active ? Color.cmuxMobileAccent : nil)
                .symbolEffect(.variableColor.iterative, isActive: active)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active ? "End Voice Mode" : "Voice Mode")
        .accessibilityIdentifier("terminal.composer.voice")
    }

    /// The rounded glass field, full width: the attachment tray on top, then
    /// paperclip, the text, voice and send on one row; the buttons ride the
    /// last line as the field grows (Messages, with its buttons inside).
    private var field: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.attachments.isEmpty {
                AttachmentStrip(model: model)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
            HStack(alignment: .bottom, spacing: 6) {
                if model.attachmentsAvailable { attachMenu }
                textView
                    .padding(.leading, model.attachmentsAvailable ? 0 : 8)
                if let source = voiceSource { voiceButton(source) }
                sendButton
            }
            .padding(TerminalDockMetrics.fieldPadding)
        }
        .frame(minHeight: TerminalDockMetrics.control, alignment: .bottom)
        // The rounded glass always wraps the whole field (see `body`).
        .fixedSize(horizontal: false, vertical: true)
        .glassSurface(in: .rect(cornerRadius: TerminalDockMetrics.fieldCornerRadius, style: .continuous))
        .animation(.smooth(duration: 0.3).unlessReduceMotion, value: model.attachments.count)
    }

    private var textView: some View {
        ComposerTextView(
            text: $model.composerText,
            placeholder: model.composerPlaceholder,
            focusRequest: model.composerFocusRequest,
            focusOnAppear: model.composerFocusOnAppear,
            isDisabled: false,
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
    }

    private var sendButton: some View {
        let canSend = !(model.composerText.isEmpty && model.attachments.isEmpty)
        let failed = model.attachmentError != nil
        return Button {
            send()
        } label: {
            ZStack {
                if model.isUploading {
                    CmuxSpinner(tint: Color.cmuxMobileOnAccent).controlSize(.small)
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
            .animation(.smooth(duration: 0.2).unlessReduceMotion, value: canSend)
        }
        .buttonStyle(.plain)
        .disabled(model.isUploading || !canSend)
        .contextMenu {
            Button("Send without Return", systemImage: "arrow.up.to.line") {
                model.sendWithoutReturn()
            }
        }
        .accessibilityLabel(model.isUploading ? "Sending" : failed ? "Send failed" : "Send")
        .accessibilityIdentifier("terminal.composer.send")
    }

    private func send() {
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

/// A button inside the composer's field (paperclip, voice): a 28 pt circle
/// of the `fill` token, not glass (never glass on glass, SPEC 2.4), the
/// send circle's size; tinted with the accent while on (voice mode running).
struct ComposerInlineCircle: View {
    let systemImage: String
    var diameter: CGFloat = TerminalDockMetrics.sendDiameter
    var foreground = AnyShapeStyle(Color.primary.opacity(0.78))
    var tint: Color?

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(tint ?? Color.cmuxMobileFill))
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

/// The attachment tray inside the composer's field: 56 x 56 thumbnails
/// (radius 12) for photos and videos, 56 h chips for files on the `fill`
/// token, each with a 20 pt remove badge on `surfaceRaised` (SPEC 4.3).
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
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Color.primary)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(Color.cmuxMobileSurfaceRaised))
                                    .overlay(Circle().strokeBorder(Color.cmuxMobileBackground.opacity(0.6), lineWidth: 1))
                                    .frame(width: 36, height: 36)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 12, y: -12)
                            .accessibilityLabel("Remove \(attachment.name)")
                        }
                }
            }
            .padding(.top, 10)
            .padding(.horizontal, 10)
            .padding(.bottom, 2)
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
            .background(Color.cmuxMobileFill, in: .rect(cornerRadius: 12, style: .continuous))
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
