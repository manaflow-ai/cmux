#if os(iOS)
import AVFoundation
import CmuxMobileArtifacts
import CmuxMobileDesign
import CmuxMobileLinkFFI
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

    #if DEBUG
    /// The accessibility probes are opt-in so ordinary debug UI tests keep the same
    /// view hierarchy and query cost as a production launch. The composer-edge test
    /// enables them explicitly when it needs to inspect hit routing.
    private var tapProbeEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-cmuxMobileComposerTapProbe")
    }
    #endif

    var body: some View {
        #if DEBUG
        let _ = InputLatencyTrace.shared?.count("composer_body")
        // The before rows: the body read the draft (onChange, the send button), as on base.
        let _ = ComposerReturnTextView.measuresWholeDraft ? model.composerText.isEmpty : false
        #endif
        // The notice, the held-keys row and the attachment error float over the terminal just above the row and take
        // no height: a card that grew for them moved `bottomStack`, and with it the terminal's bottom inset, the
        // prompt and the grid (Leo 2026-11-24: "this thing's shifting affects the composer at the bottom ... we need
        // to have more things decoupled from possible shifts"; same rule as the connection chip, #49316).
        // No connection line here: a reattach takes no row (Leo, 2026-11-17: "The reconnect takes an extra line").
        // The state is the title pill's subtitle and Reconnect is in the page menu, both only past the quiet bound
        // (`TerminalModel.connectionLine`).
        VStack(alignment: .leading, spacing: 6) {
            card
        }
        .overlay(alignment: .topLeading) { floatingNotes }
        #if DEBUG
        .background(alignment: .bottomLeading) {
            if tapProbeEnabled {
                KeyBarFiredProbe(model: model)
            }
        }
        #endif
        .padding(.horizontal, ComposerCardMetrics.horizontalInset)
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
            loadPhotos(items)
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

    /// The not-sent notice and the attachment error, drawn over the terminal above the card (its top edge is their
    /// bottom edge), never in the card's stack: they take no height and move nothing.
    @ViewBuilder private var floatingNotes: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let notice = model.composerNotice {
                Label(notice, systemImage: "exclamationmark.arrow.circlepath")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("terminal.composer.notSent")
            } else if model.heldKeyBytes > 0 {
                // Keys typed before the attach go into whatever the terminal shows after it: this row says they are
                // pending, with Discard (the one tappable note). Gone at the attach, or when they are dropped.
                HStack(spacing: 8) {
                    Label(TerminalConnectionState.inputHeldNotice, systemImage: "clock.arrow.circlepath")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                    Button("Discard") { model.discardHeldKeys() }
                        .font(.footnote.weight(.semibold))
                        .accessibilityIdentifier("terminal.composer.heldKeys.discard")
                }
                .accessibilityIdentifier("terminal.composer.heldKeys")
            }
            if let error = model.attachmentError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("terminal.composer.attachmentError")
            }
        }
        .padding(.leading, ComposerCardMetrics.rowInset + 8)
        .padding(.bottom, 4)
        .fixedSize(horizontal: false, vertical: true)
        .alignmentGuide(.top) { $0[.bottom] }
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
            Image(systemName: "plus")
                .font(.system(size: 17))
                .composerControlCircle(Color.cmuxMobileFill)
        }
        .accessibilityLabel("Add Attachment")
        .accessibilityIdentifier("terminal.composer.attach")
    }

    /// The agent chat's card (``ComposerCard``): `+` (and voice when it sits left), the draft,
    /// Send, on one row while the draft fits; attachments over them inside the card. On the
    /// terminal theme's colors over the same Liquid Glass, so it reads as part of the pane.
    private var card: some View {
        ComposerCard(look: look.card, lineHeight: UIFont.preferredFont(forTextStyle: .body).lineHeight) {
            // Strip and text share the cap: the field gives the strip its
            // height, and the page's inset leaves out what reaches above the
            // field's own height, so no row moves (Leo, 2026-11-23: "simply
            // have it within the top part of the composer. the inner area grows
            // at the top. no shift, nothing.").
            if !model.attachments.isEmpty {
                AttachmentStrip(model: model)
                    .frame(height: ComposerHeightCap.stripHeight, alignment: .top)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        } leading: {
            HStack(spacing: 0) {
                attachMenu
                if voice.placement == .leading, let source = model.voiceSource { TerminalComposerVoiceSlot(source: source, ink: look.ink) }
            }
        } field: {
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
                autocorrect: autocorrect,
                stripReserve: ComposerHeightCap.stripReserve(hasAttachments: !model.attachments.isEmpty),
                fieldRef: model.composerField
            )
        } trailing: {
            HStack(spacing: 0) {
                // "Beside Send": a waveform just left of send, which stays send
                // (Claude's and ChatGPT's composers keep voice next to send).
                if voice.placement.voiceBesideSend, let source = voiceSource {
                    besideSendVoiceButton(source)
                }
                primaryButton
            }
        }
        .foregroundStyle(look.ink)
        // The card's own id (ComposerCard is one container element, #55113), so a test
        // can find the card: ComposerGlassColorUITests samples its glass as the draft grows.
        .accessibilityIdentifier("terminal.composer.card")
    }

    /// The pane's colors: the Mac's terminal theme, else the app default.
    private var look: TerminalPillLook { TerminalPillLook(theme: model.hostTheme) }

    /// "Beside Send": a plain waveform the size of the send circle, so the
    /// field keeps one filled circle (send); voice mode on fills it.
    private func besideSendVoiceButton(_ source: any AgentVoiceSource) -> some View {
        let active = voice.isActive(source.voiceSourceID)
        return Button {
            voice.toggle(source)
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: active ? .bold : .regular))
                .foregroundStyle(active ? AnyShapeStyle(Color.cmuxMobileOnAccent) : AnyShapeStyle(look.ink))
                .symbolEffect(.variableColor.iterative, isActive: active)
                .composerControlCircle(active ? AnyShapeStyle(Color.cmuxMobileAccent) : AnyShapeStyle(Color.clear))
        }
        .buttonStyle(.cmuxPressFillInLabel)
        .accessibilityLabel(active ? "End Voice Mode" : "Voice Mode")
        .accessibilityIdentifier("terminal.composer.voice")
    }

    /// Send, or with "In Send Button" and nothing to send, voice mode (the
    /// ChatGPT composer): one circle, never a disabled send beside a mic.
    @ViewBuilder private var primaryButton: some View {
        let empty = !model.composerHasText && model.attachments.isEmpty
        if let source = voiceSource,
           voice.placement.sendCircleIsVoice(nothingToSend: empty && !model.isUploading,
                                             voiceActive: voice.isActive(source.voiceSourceID)) {
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
                .composerControlCircle(Color.cmuxMobileAccent)
        }
        .buttonStyle(.cmuxPressFillInLabel)
        .accessibilityLabel(active ? "End Voice Mode" : "Voice Mode")
        .accessibilityIdentifier("terminal.composer.voice")
    }

    private var sendButton: some View {
        let canSend = model.composerHasText || !model.attachments.isEmpty
        let failed = model.attachmentError != nil
        return Button {
            if model.isUploading { model.cancelSend() } else { send() }
        } label: {
            ZStack {
                if model.isUploading {
                    // Stop, never a dead spinner: the send can always be called off.
                    CmuxSpinner(tint: Color.cmuxMobileOnSend).controlSize(.regular)
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.cmuxMobileOnSend)
                } else {
                    Image(systemName: failed ? "exclamationmark" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(failed ? AnyShapeStyle(CmuxMobileTheme.standard.colors.onAccent.color) : canSend ? AnyShapeStyle(Color.cmuxMobileOnSend) : AnyShapeStyle(Color(uiColor: .tertiaryLabel)))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            // The agent chat's Send: a solid disc of the theme's Send color
            // (`Color.cmuxMobileSend`, never a white disk). Tinted glass washed
            // it out to a pale disc (Leo, 2026-11-22: "the send button is
            // themed/coloured slightly oddly"). Empty (disabled): the faint fill.
            .composerControlCircle(failed ? AnyShapeStyle(CmuxMobileTheme.standard.colors.danger.color)
                                   : canSend || model.isUploading ? AnyShapeStyle(Color.cmuxMobileSend)
                                   : AnyShapeStyle(Color.cmuxMobileFill))
            .animation(.smooth(duration: 0.2).unlessReduceMotion, value: canSend)
        }
        .buttonStyle(.cmuxPressFillInLabel)
        .disabled(!model.isUploading && !canSend)
        .contextMenu {
            Button("Send without Return", systemImage: "arrow.up.to.line") {
                model.sendWithoutReturn()
            }
        }

        .accessibilityLabel(model.isUploading ? CmuxMobileTerminalAccessibility.cancelSending : failed ? "Send failed" : "Send")

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
            let stamp = Self.stamp()
            for (index, item) in board.composerImages().enumerated() {
                let ext = UTType(mimeType: item.mimeType)?.preferredFilenameExtension ?? "png"
                let suffix = index == 0 ? "" : " \(index + 1)"
                let thumbnail = UIImage(data: item.data)?.preparingThumbnail(of: CGSize(width: 168, height: 168))
                model.addAttachment(ComposerAttachment(
                    kind: .image, name: "Pasted image \(stamp)\(suffix).\(ext)",
                    thumbnail: thumbnail, data: item.data))
            }
        case .file(let url):
            Task { await loadFiles([url]) }
        case .text(let text):
            model.composerText += text
        case .nothing:
            break
        }
    }

    // MARK: Loading attachments

    /// Photos can be backed by iCloud and may leave a provider request open
    /// indefinitely. Each tile owns a cancellable, bounded request so removing
    /// one item does not hold up the other picks.
    private enum PhotoLoadError: LocalizedError {
        case deadline
        case unavailable

        var errorDescription: String? {
            switch self {
            case .deadline:
                String(localized: "terminal.photos.deadline", defaultValue: "Photos took too long to provide this item.", bundle: .module)
            case .unavailable:
                String(localized: "terminal.photos.unavailable", defaultValue: "Photos could not provide this item.", bundle: .module)
            }
        }
    }

    /// Resolves the caller as soon as either the provider or the inactivity
    /// deadline wins. A late Photos callback is ignored after the continuation
    /// has been resumed.
    private final class PhotoLoadRace<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var result: Result<Value, Error>?

        func install(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }

        @discardableResult
        func finish(_ result: Result<Value, Error>) -> Bool {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return false
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
            return true
        }
    }

    static func loadWithInactivityDeadline<T: Sendable>(
        _ operation: (@escaping @Sendable (Result<T?, Error>) -> Void) -> Progress,
        inactivityDeadline: Duration = .seconds(30),
        progressPoll: Duration = .milliseconds(250)
    ) async throws -> T {
        try Task.checkCancellation()
        let race = PhotoLoadRace<T?>()
        let progress = operation { [weak race] result in _ = race?.finish(result) }
        let monitor = Task {
            let clock = ContinuousClock()
            var lastFraction = progress.fractionCompleted
            var lastAdvance = clock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: progressPoll) }
                catch { return }
                let fraction = progress.fractionCompleted
                if fraction > lastFraction {
                    lastFraction = fraction
                    lastAdvance = clock.now
                } else if clock.now - lastAdvance >= inactivityDeadline {
                    if race.finish(.failure(PhotoLoadError.deadline)) { progress.cancel() }
                    return
                }
            }
        }
        defer { monitor.cancel() }
        let value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
            }
        } onCancel: {
            monitor.cancel()
            if race.finish(.failure(CancellationError())) { progress.cancel() }
        }
        guard let value else { throw PhotoLoadError.unavailable }
        return value
    }

    /// Picked photos and videos keep their bytes (a video its local copy).
    /// Photos has no file name for an item without library access, so the
    /// name says what it is and when it was attached.
    private func loadPhotos(_ items: [PhotosPickerItem]) {
        let stamp = Self.stamp()
        for (index, item) in items.enumerated() {
            let suffix = items.count > 1 ? " \(index + 1)" : ""
            let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
            let ext = item.supportedContentTypes.first { type in
                isVideo ? type.conforms(to: .movie) : type.conforms(to: .image)
            }?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
            let kind: ComposerAttachment.Kind = isVideo ? .video : .image
            let placeholder = ComposerAttachment(kind: kind,
                                                  name: "\(isVideo ? "Video" : "Photo") \(stamp)\(suffix).\(ext)",
                                                  isLoading: true)
            model.loadPickedAttachment(placeholder) { [item] in
                if isVideo {
                    let movie: MovieFile = try await Self.loadWithInactivityDeadline { completion in
                        item.loadTransferable(type: MovieFile.self, completionHandler: completion)
                    }
                    let thumbnail = await Self.videoThumbnail(movie.url)
                    let size = (try? movie.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                    return .movie(movie.copy, thumbnail: thumbnail, byteCount: size)
                }
                let data: Data = try await Self.loadWithInactivityDeadline { completion in
                    item.loadTransferable(type: Data.self, completionHandler: completion)
                }
                guard let image = UIImage(data: data) else { throw PhotoLoadError.unavailable }
                let thumbnail = await image.byPreparingThumbnail(ofSize: CGSize(width: 168, height: 168))
                return .image(data, thumbnail: thumbnail)
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

#if DEBUG
/// DEBUG, for TerminalComposerTapBleedUITests: which key-row keys fired ("count:id") and how
/// many touches reached the joystick, so a test can tell that a tap on the composer reached no
/// key. Its own view: only it reads the counters, never the composer's body.
private struct KeyBarFiredProbe: View {
    let model: TerminalModel

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Key row probe")
                .accessibilityValue("\(model.keyBarFired)|joystick:\(model.joystickEngine.touches)")
                .accessibilityIdentifier("terminal.keyBar.fired")
            // Where typed keys go: "terminal" while the surface has them, else "composer".
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityLabel("Typing target probe")
                .accessibilityValue(model.directTyping ? "terminal" : "composer")
                .accessibilityIdentifier("terminal.typingTarget")
        }
        .allowsHitTesting(false)
    }
}
#endif

/// The composer's quiet chrome on the terminal theme's background.
enum ComposerChrome {
    /// The field's and the + circle's hairline: it alone marks them.
    static let border = Color.primary.opacity(0.16)
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
    let copy: PickedMovieCopy
    var url: URL { copy.url }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            MovieFile(copy: try PickedMovieCopy(copying: received.file))
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
                                    .foregroundStyle(CmuxMobileTheme.standard.colors.label.color)
                                    .frame(width: 22, height: 22)
                                    // The theme's floating glass (its surface at the transient veil),
                                    // so it reads over any thumbnail and follows the Mac's theme.
                                    .cmuxMobileFloatingGlass(in: .circle, interactive: true)
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
            .overlay { AttachmentUploadBadge(attachment: attachment, progress: model.uploadProgress(attachment)) }
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
            .overlay { AttachmentUploadBadge(attachment: attachment, progress: model.uploadProgress(attachment)) }
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .glassSurface(in: .rect(cornerRadius: 12, style: .continuous))
        }
    }
}

/// A tile's upload state over its thumbnail: a spinner while Photos copies it
/// or it is compressed or waits for the Mac, a ring of the bytes the Mac has,
/// a check when it is there, a mark when it failed (Send tries again).
struct AttachmentUploadBadge: View {
    let attachment: ComposerAttachment
    let progress: UploadProgress?
    @State private var waitingGate = QuietStatusGate()

    var body: some View {
        badge
            .onChange(of: isWaitingForMac, initial: true) { _, waiting in
                waitingGate.update(down: waiting)
            }
            .onDisappear { waitingGate.update(down: false) }
    }

    private var isWaitingForMac: Bool {
        !attachment.isLoading && progress?.stage == .waitingForMac
    }

    @ViewBuilder private var badge: some View {
        if attachment.isLoading {
            scrim { CmuxSpinner(tint: .white).controlSize(.small) }
                .accessibilityLabel("Loading \(attachment.name)")
        } else if let progress {
            switch progress.stage {
            case .compressing:
                scrim { CmuxSpinner(tint: .white).controlSize(.small) }
                    .accessibilityLabel("Compressing")
            case .waitingForMac:
                if waitingGate.isShown {
                    scrim { CmuxSpinner(tint: .white).controlSize(.small) }
                        .accessibilityLabel("Waiting for the Mac")
                }
            case .uploading, .finishing:
                scrim {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.3), lineWidth: 3)
                        Circle().trim(from: 0, to: max(0.02, progress.fraction))
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.2), value: progress.fraction)
                    }
                    .frame(width: 26, height: 26)
                }
                .accessibilityLabel("Uploading")
                .accessibilityValue("\(Int((progress.fraction * 100).rounded())) percent")
            case .failed:
                scrim { Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white) }
                    .accessibilityLabel(progress.errorMessage ?? "Upload failed")
            case .done, .cancelled:
                EmptyView()
            }
        }
    }

    private func scrim(@ViewBuilder _ content: () -> some View) -> some View {
        ZStack {
            Color.black.opacity(0.35)
            content()
        }
        .allowsHitTesting(false)
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

/// The voice circle, when the tab's agent offers voice (`AgentVoiceSource.voiceAvailable`).
/// Its own view so what that reads (the store's workspaces, moved by every Mac push)
/// re-renders this circle alone, never the composer's field (ask-4a87599079).
private struct TerminalComposerVoiceSlot: View {
    let source: any AgentVoiceSource
    /// The terminal theme's ink, as on the card's other controls.
    let ink: Color
    private let voice = AgentVoiceLauncher.shared

    var body: some View {
        if source.voiceAvailable, voice.isAvailable {
            let active = voice.isActive(source.voiceSourceID)
            // The card's control circle (`composerControlCircle`), as the chat's composer draws it:
            // filled and moving while voice runs here; a tap ends it.
            Button {
                voice.toggle(source)
            } label: {
                Image(systemName: "waveform")
                    .font(.system(size: 17))
                    .foregroundStyle(active ? AnyShapeStyle(Color.cmuxMobileOnAccent) : AnyShapeStyle(ink))
                    .symbolEffect(.variableColor.iterative, isActive: active)
                    .composerControlCircle(active ? Color.cmuxMobileAccent : Color.clear)
            }
            .buttonStyle(.cmuxPressFillInLabel)
            .accessibilityLabel(active ? "End Voice Mode" : "Voice Mode")
            .accessibilityIdentifier("terminal.composer.voice")
        }
    }
}
#endif
