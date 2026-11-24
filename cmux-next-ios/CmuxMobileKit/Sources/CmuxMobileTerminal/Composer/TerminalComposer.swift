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

/// The composer row: a + menu (Photo Library, Choose Files, Paste, Camera)
/// in a 40 pt glass circle, then the growing field in a rounded glass
/// container with the send circle inside it, riding the last line. Picked
/// attachments sit inside the field, above the text and starting where it
/// starts (Messages, ChatGPT, Claude). Voice mode has no button unless the
/// user turns one on (Settings → Composer; Leo, 2026-11-22: "im hiding
/// this by default"); then it is the send circle while the draft is empty, or
/// a circle left of the field. Why each control is here, with sources:
/// cmuxterm-hq docs/design/ios-composer-controls.md. Send delivers the draft as one
/// paste plus Return (`ComposerSubmit`); Return in the field starts a new line.
/// It sits below the key row, nearest the keyboard, and is open by default.
/// Jump to bottom floats above the key row and takes no space (`TerminalJumpToBottomRow`).
struct TerminalComposer: View {
    @Bindable var model: TerminalModel
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    private let voice = AgentVoiceLauncher.shared
    /// The + menu's Autocorrect toggle, remembered across launches (off by
    /// default; Settings → Terminal shows the same key).
    @AppStorage(CmuxMobilePreferences.Key.terminalComposerAutocorrect)
    private var autocorrect = CmuxMobilePreferences.defaultTerminalComposerAutocorrect

    var body: some View {
        #if DEBUG
        let _ = InputLatencyTrace.shared?.count("composer_body")
        // The before rows: the body read the draft (onChange, the send button), as on base.
        let _ = ComposerReturnTextView.measuresWholeDraft ? model.composerText.isEmpty : false
        #endif
        VStack(alignment: .leading, spacing: 6) {
            if let notice = model.composerNotice {
                Label(notice, systemImage: "exclamationmark.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.leading, TerminalDockMetrics.control + 8)
                    .accessibilityIdentifier("terminal.composer.notSent")
            }
            // No connection line here: a reattach takes no row (Leo,
            // 2026-11-17: "The reconnect takes an extra line"). The state is
            // the title pill's subtitle and Reconnect is in the page menu,
            // both only past the quiet bound (`TerminalModel.connectionLine`).
            if let error = model.attachmentError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.leading, TerminalDockMetrics.control + 8)
                    .accessibilityIdentifier("terminal.composer.attachmentError")
            }
            GlassEffectContainer(spacing: 0) {
                HStack(alignment: .bottom, spacing: 8) {
                    attachMenu
                    if voice.placement == .leading, let source = voiceSource { voiceButton(source) }
                    fieldContainer
                }
            }
        }
        .padding(.horizontal, TerminalDockMetrics.horizontalInset)
        // Always its own height, never the hosting view's current one (kept
        // from #41900): the hosting view takes a taller row's height a pass
        // after SwiftUI measures it, and a min-height frame offered less
        // takes the offer. The draft that ran below the field (user reports
        // 2026-11-12 and 2026-11-13) came from the text view's old sizing,
        // which `ComposerReturnTextView.fittingSize` replaced;
        // ComposerGrowUpUITests holds the field's bottom edge in place.
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

    /// The terminal's agent, when voice mode can run on it.
    private var voiceSource: (any AgentVoiceSource)? {
        guard let source = model.voiceSource, source.voiceAvailable else { return nil }
        return source
    }

    /// + as in Messages, Slack, ChatGPT, Claude and Discord: the menu adds
    /// photos, files, a paste and the camera, not only files (a paperclip
    /// reads as "attach a file", Mail's meaning). Classic's order: Photo
    /// Library, Choose Files, Paste; then Camera. Last, the Autocorrect
    /// toggle (Leo, 2026-11-24: "an autocorect toggle in the terminal
    /// composer would be good"), so the menu shows even with no Mac to take
    /// attachments.
    private var attachMenu: some View {
        Menu {
            if model.attachmentsAvailable {
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
            }
            Section {
                Toggle(isOn: $autocorrect) {
                    Label("Autocorrect", systemImage: "textformat.abc")
                }
                .accessibilityIdentifier("terminal.composer.autocorrect")
            }
        } label: {
            ComposerCircleLabel(systemImage: "plus")
        }
        .buttonStyle(.cmuxPressFillInLabel)
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
            ComposerCircleLabel(systemImage: "waveform",
                                foreground: active ? AnyShapeStyle(Color.cmuxMobileOnAccent) : AnyShapeStyle(Color.primary.opacity(0.78)),
                                tint: active ? Color.cmuxMobileAccent : nil)
                .symbolEffect(.variableColor.iterative, isActive: active)
        }
        .buttonStyle(.cmuxPressFillInLabel)
        .accessibilityLabel(active ? "End Voice Mode" : "Voice Mode")
        .accessibilityIdentifier("terminal.composer.voice")
    }

    /// The field and its send circle share one rounded glass container; the
    /// circle rides the last line as the field grows (classic, iMessage).
    private var fieldContainer: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Inside the field, where the text starts: one attachment sits
            // over the draft's first letter, never in the far corner from send.
            if !model.attachments.isEmpty {
                AttachmentStrip(model: model)
                    .padding(.leading, -AttachmentStrip.edgeInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            fieldRow
        }
        .padding(.leading, 14)
        .padding(.trailing, TerminalDockMetrics.fieldPadding)
        // No vertical padding around the text: the text view runs from the
        // field's top edge to its bottom edge (`textVerticalInset` keeps the
        // text off them), so a scrolled draft is cut exactly at the edge. The
        // rounded shape clips the cut lines at the corners too.
        .frame(minHeight: TerminalDockMetrics.control, alignment: .top)
        .clipShape(.rect(cornerRadius: TerminalDockMetrics.fieldCornerRadius, style: .continuous))
        // The terminal theme's own background with a hairline border, not
        // glass: glass lifted the field lighter than the pane (Leo,
        // 2026-11-22: "dont draw unnecessary attention by making it light";
        // the border alone marks it). A flat fill also looks the same at
        // every height (Leo, 2026-11-21: "the composer brightening up when
        // you have >3 lines"; TerminalComposerLookUITests: 1, 3, 4, 8 lines).
        .background(themeBackground, in: .rect(cornerRadius: TerminalDockMetrics.fieldCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TerminalDockMetrics.fieldCornerRadius, style: .continuous)
                .strokeBorder(ComposerChrome.border, lineWidth: 1)
        }
    }

    /// The pane's background: the Mac's terminal theme, else the app default.
    private var themeBackground: Color {
        Color(uiColor: model.hostTheme?.backgroundColor ?? CmuxMobileGhosttyApp.background)
    }

    private var fieldRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
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
                onPasteAttachments: model.attachmentsAvailable ? { pasteFromClipboard() } : nil,
                autocorrect: autocorrect
            )
            primaryButton
                .padding(.vertical, TerminalDockMetrics.fieldPadding)
        }
    }

    /// Send, or with "In Send Button" and nothing to send, voice mode (the
    /// ChatGPT composer): one circle, never a disabled send beside a mic.
    @ViewBuilder private var primaryButton: some View {
        let empty = !model.composerHasText && model.attachments.isEmpty
        if voice.placement == .sendButton, let source = voiceSource,
           (empty && !model.isUploading) || voice.isActive(source.voiceSourceID) {
            sendCircleVoiceButton(source)
        } else {
            sendButton
        }
    }

    private func sendCircleVoiceButton(_ source: any AgentVoiceSource) -> some View {
        let active = voice.isActive(source.voiceSourceID)
        return Button {
            voice.toggle(source)
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.cmuxMobileOnAccent)
                .symbolEffect(.variableColor.iterative, isActive: active)
                .frame(width: TerminalDockMetrics.sendDiameter, height: TerminalDockMetrics.sendDiameter)
                .cmuxMobilePressBackground(Color.cmuxMobileAccent, in: Circle())
        }
        .buttonStyle(.cmuxPressFillInLabel)
        .accessibilityLabel(active ? "End Voice Mode" : "Voice Mode")
        .accessibilityIdentifier("terminal.composer.voice")
    }

    private var sendButton: some View {
        let canSend = model.composerHasText || !model.attachments.isEmpty
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
            // ↑ (send) is the primary action: a solid disc of the accent (the
            // Mac's when Match Mac is on), as the Mac composer's send. Tinted
            // glass washed it out to a pale disc (Leo, 2026-11-22: "the send
            // button is themed/coloured slightly oddly"). Empty (disabled): a
            // faint disc of the text color.
            .cmuxMobilePressBackground(failed ? AnyShapeStyle(Color.red)
                                       : canSend || model.isUploading ? AnyShapeStyle(Color.cmuxMobileAccent)
                                       : AnyShapeStyle(ComposerChrome.idleFill), in: Circle())
            .animation(.smooth(duration: 0.2).unlessReduceMotion, value: canSend)
        }
        .buttonStyle(.cmuxPressFillInLabel)
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

/// A 40 pt glass circle with an icon: the composer's + and, when turned on, voice.
struct ComposerCircleLabel: View {
    let systemImage: String
    var foreground = AnyShapeStyle(Color.primary.opacity(0.78))
    /// On (voice mode running): glass tinted like the send circle.
    var tint: Color?

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(width: TerminalDockMetrics.control, height: TerminalDockMetrics.control)
            // Off: the pane shows through, ringed like the field (no lighter
            // glass disc, Leo 2026-11-22). On: a solid accent disc, as send.
            .cmuxMobilePressBackground(tint ?? Color.clear, in: Circle())
            .overlay { Circle().strokeBorder(tint == nil ? ComposerChrome.border : .clear, lineWidth: 1) }
            .contentShape(.circle)
    }
}

/// The composer's quiet chrome on the terminal theme's background.
enum ComposerChrome {
    /// The field's and the + circle's hairline: it alone marks them.
    static let border = Color.primary.opacity(0.16)
    /// The disabled send disc.
    static let idleFill = Color.primary.opacity(0.08)
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
    /// The strip's own inset around its tiles (room for the remove badges).
    static let edgeInset: CGFloat = 8

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
                            .buttonStyle(.cmuxPressGlass)
                            .offset(x: 16, y: -16)
                            .accessibilityLabel("Remove \(attachment.name)")
                        }
                }
            }
            .padding(.top, Self.edgeInset + 4)
            .padding(.horizontal, Self.edgeInset)
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
