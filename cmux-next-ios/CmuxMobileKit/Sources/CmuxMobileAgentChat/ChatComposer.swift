import CmuxMobileArtifacts
#if os(iOS)
import CmuxAgentBrands
import CmuxMobileDesign
import CmuxMobileRealtime
import CmuxMobileTransport
import CmuxSpinner
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// SPEC 4.3 composer for agent chat: one glass card whose one row holds the `+` menu, the text,
/// the model pill and send/stop (`ComposerRowLayout`, the text above them once it wraps), attachment previews,
/// queue rows, slash-command suggestions, and the collapsed capsule (same placeholder as the field).
struct ChatComposer: View {
    let store: AgentChatStore
    @Binding var text: String
    @Binding var attachments: [AgentAttachment]
    /// The field's focus (the field is a UITextView, so this is a plain binding
    /// it follows both ways, not a `FocusState`).
    var focus: Binding<Bool>
    var collapsible: Bool
    /// Expand and focus as soon as the composer appears (Reply instead,
    /// which swaps the permission bar back to the composer).
    var expandOnAppear = false
    /// Replaces "Reply to <chat>" (e.g. while replying instead of a permission).
    var placeholderOverride: String?
    /// Sending answers the pending permission with a denial plus this message.
    var denyingPermission = false
    /// Window y the slash-command list may not rise above (under the chat's header and
    /// what the bottom stack shows over the composer); nil when the host does not say.
    var suggestionsCeiling: CGFloat?
    /// The cmux commands this chat offers (`/status`, `/fork`, `/continue`), listed before the
    /// agent's own, and what runs one when it is sent alone: nil when it ran, else the refusal
    /// shown over the composer (the draft stays). Empty: none offered.
    var cmuxCommands: [CmuxSlashCommand] = []
    var runCmuxCommand: (@MainActor (CmuxSlashCommand, String) async -> String?)?
    /// Where the screen reads how far the attachment strip reaches above the
    /// field's own height (the transcript's inset leaves it out).
    var fieldRef: ComposerFieldRef?
    @State private var showPhotos = false
    @AppStorage(ComposerFooterFactsMode.key) private var footerFactsMode = ComposerFooterFactsMode.off.rawValue
    private let voice = AgentVoiceLauncher.shared
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    /// Picked videos Photos is still copying out (a large one takes seconds): a chip each.
    @State private var preparingVideos = 0
    @State private var optimizingImageIDs = Set<String>()
    /// An attachment tapped before sending: previewed full screen.
    @State private var preview: FilePreviewRequest?
    @State private var sendCount = 0
    @State private var planMode = false
    #if DEBUG
    @State private var ranOfflineSendDemo = false
    #endif
    /// Set by a tap on the collapsed capsule: the text field only exists
    /// when expanded, so focus can only move into it after it is built.
    @State private var expandRequested = false
    /// The composer card's top, window y: the slash-command list's bottom edge less the
    /// stack's spacing, so its height bound's floor. Measured on the card, which is laid out
    /// before the list exists and which the list never moves, so the list opens at its one
    /// final height. Measured on the list itself it was unknown on the list's first frame:
    /// the list drew at the 5.5-row fallback, then shrank (or grew) a frame later to the real
    /// room, a second animation on top of its entrance.
    @State private var cardTop: CGFloat?
    /// The space between the list (or the mention list) and the card.
    private static let suggestionsGap: CGFloat = 8
    /// The session's files for `@` mentions, scanned once per transcript change, not per key.
    @State private var mentionIndex = MentionIndex()

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Read by the body on every key: stops at the draft's first visible character, where
    /// trimming copied the whole draft through Foundation per key (ComposerTypingLagUITests).
    private var hasContent: Bool {
        #if DEBUG
        if ComposerReturnTextView.measuresWholeDraft { return !trimmed.isEmpty || !attachments.isEmpty }
        #endif
        return text.contains(where: { !$0.isWhitespace }) || !attachments.isEmpty
    }
    private var collapsedTarget: Bool { collapsible && !focus.wrappedValue && !hasContent && !expandRequested }
    /// Follows `collapsedTarget` inside an explicit `.cmuxMobileSmooth` animation.
    /// Losing focus to the keyboard's dismissal changes the target in an
    /// update that carries no animation, and the capsule snapped shut while
    /// the transcript above it eased down (verify/keyboard.md).
    @State private var shownCollapsed: Bool?
    private var collapsed: Bool { shownCollapsed ?? collapsedTarget }
    /// `collapsible` as last placed: it flips when the chat's first turns come.
    @State private var placedCollapsible: Bool?
    #if DEBUG
    @State private var didFillTypingDemo = false
    #endif

    var body: some View {
        #if DEBUG
        let _ = InputLatencyTrace.shared?.count("composer_body")
        let _ = InputLatencyTrace.shared?.note("chat_composer_body")
        #endif
        VStack(spacing: Self.suggestionsGap) {
            if !slashMatches.isEmpty {
                slashSuggestions
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let mention = ComposerMention(text: text), !mentionMatches(mention).isEmpty {
                mentionSuggestions(mention)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            card
                // The card's top, which only the keyboard, the resting place or the card's own
                // growth moves (the stack is bottom-aligned), so the list's height never feeds back.
                .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).minY }) { top in
                    if cardTop != top { cardTop = top }
                }
        }
        .animation(.cmuxMobileSmooth.unlessReduceMotion, value: collapsed)
        .animation(.cmuxMobileSnappy.unlessReduceMotion, value: attachments)
        .filePreview($preview)
        // Photos and videos, as the Mac's composer takes both (a video goes with its frames).
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let (files, refused) = Self.readFiles(urls)
                appendPreparedFiles(files)
                if let refused { store.clientError = refused }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: AgentImageOptimizer.jpegQuality) {
                    let name = "Camera \(Date().formatted(date: .omitted, time: .shortened))"
                    appendOptimizedImage(data, name: name)
                }
            }
            .ignoresSafeArea()
        }
        // Files start for the Mac the moment they are picked, not at Send (AttachmentPrestager).
        .onChange(of: attachments.map(\.id), initial: true) { _, _ in
            syncPreparedAttachments()
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .cmuxMobileSensoryFeedback(.impact(weight: .light), trigger: sendCount)
        .onChange(of: expandRequested && focus.wrappedValue) { _, expansionFocused in
            if expansionFocused { expandRequested = false }
        }
        .onAppear {
            if expandOnAppear { expand() }
            #if DEBUG
            guard !didFillTypingDemo,
                  let mode = ProcessInfo.processInfo.environment["CMUX_MOBILE_DEMO_CHAT_COMPOSER"],
                  mode.hasPrefix("chars:"), text.isEmpty,
                  let count = Int(mode.dropFirst("chars:".count).prefix(while: \.isNumber)) else { return }
            didFillTypingDemo = true
            text = Self.demoTypingText(count, oneParagraph: mode.hasSuffix(":oneline"))
            focus.wrappedValue = true
            #endif
        }
        #if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-cmux-mobile-demo"),
                  arguments.indices.contains(index + 1), ["offline-send", "offline-held"].contains(arguments[index + 1]),
                  !ranOfflineSendDemo else { return }
            ranOfflineSendDemo = true
            text = "Run the tests and summarize the results."
            send(steer: false)
        }
        #endif
        // A returned prompt the Mac turned out to have run: out of the composer again,
        // unless the person already changed it.
        .onChange(of: store.withdrawnDraft) { _, draft in
            guard let draft else { return }
            store.withdrawnDraft = nil
            if trimmed == draft.text.trimmingCharacters(in: .whitespacesAndNewlines) { text = "" }
            attachments.removeAll { own in draft.attachments.contains { $0.id == own.id } }
        }
        // A prompt that never reached the agent comes back to the composer, also when it came
        // back before the chat opened (New Task's task that never left the phone).
        .onChange(of: store.returnedDraft, initial: true) { _, draft in
            guard let draft else { return }
            store.returnedDraft = nil
            // Typed meanwhile: the returned text goes before it, never lost.
            text = trimmed.isEmpty ? draft.text : draft.text + "\n\n" + text
            attachments = draft.attachments + attachments.filter { own in !draft.attachments.contains { $0.id == own.id } }
        }
        // The flip is placed even when the target stays (focused or drafting as the history
        // came), so a later collapse by the person is not taken for the chat opening.
        .onChange(of: collapsible) { _, now in if !collapsedTarget { placedCollapsible = now } }
        .onChange(of: collapsedTarget, initial: true) { _, target in
            // A chat opening on its history (a replayed batch brought its first turns)
            // shows the collapsed composer at once, not the empty chat's composer collapsing.
            let opened = store.lastChangeWasReplay && placedCollapsible == false && collapsible
            placedCollapsible = collapsible
            guard shownCollapsed != target else { return }
            if shownCollapsed == nil || opened {
                if opened { store.placeBottomStackInstantly = true }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { shownCollapsed = target }
            } else {
                withAnimation(.cmuxMobileSmooth.unlessReduceMotion) { shownCollapsed = target }
            }
        }
    }

    #if DEBUG
    /// ComposerTypingLagUITests' long draft: the terminal's demo prose (a paragraph break every
    /// four sentences), or with `oneParagraph` the same text as a single paragraph.
    private static func demoTypingText(_ count: Int, oneParagraph: Bool) -> String {
        let sentence = "The build fails on the second step when the cache is cold, so check the log and the screenshots before rerunning it. "
        var text = ""
        var index = 0
        while text.utf8.count < count {
            text += sentence
            index += 1
            if index % 4 == 0, !oneParagraph { text += "\n\n" }
        }
        // End on a word boundary: a draft cut mid-word ("...befo") fuses the first typed word
        // into it ("befothe"), and autocorrect then rewrites that word, so the keys a test typed
        // are not the text it reads back. The length stays exactly `count`.
        guard count > 0 else { return "" }
        let cut = String(text.prefix(count - 1))
        return cut.hasSuffix("\n") ? cut + "\n" : cut + " "
    }
    #endif

    /// A copied image or file pasted into the field: attached as Photos or
    /// Files would attach it (`UIPasteboard.composerImages`).
    private func pasteAttachments() {
        let board = UIPasteboard.general
        if board.hasImages {
            let stamp = Date().formatted(date: .omitted, time: .shortened)
            let images = board.composerImages().enumerated().map { index, image in
                let suffix = index > 0 ? " \(index + 1)" : ""
                return (name: "Pasted image \(stamp)\(suffix)", data: image.data)
            }
            for image in images { appendOptimizedImage(image.data, name: image.name) }
        } else if board.composerHoldsFileData {
            // A file copied in Files is its bytes on the pasteboard, not a path.
            let providers = board.itemProviders
            Task {
                let pasted = await ComposerPastedFiles.load(providers)
                for file in pasted.files {
                    let isImage = file.type.conforms(to: .image)
                    if !isImage {
                        attachments.append(AgentAttachment(kind: .file, name: file.name, data: file.data,
                                                           fileURL: file.fileURL, byteCount: file.byteCount))
                    } else if let original = file.data {
                        appendOptimizedImage(original, name: file.name, fileURL: file.fileURL, byteCount: file.byteCount)
                    } else {
                        appendOptimizedImage(fileURL: file.fileURL, name: file.name, byteCount: file.byteCount)
                    }
                }
                if let name = pasted.unreadable.first { store.clientError = "Couldn't read \(name)." }
            }
        } else if let urls = board.urls?.filter(\.isFileURL), !urls.isEmpty {
            let (files, refused) = Self.readFiles(urls)
            appendPreparedFiles(files)
            if let refused { store.clientError = refused }
        }
    }


    private func syncPreparedAttachments() {
        store.composerAttachmentsChanged(attachments.filter { !optimizingImageIDs.contains($0.id) })
    }

    private func appendPreparedFiles(_ files: [AgentAttachment]) {
        for file in files {
            if file.kind == .image, let data = file.data {
                appendOptimizedImage(data, name: file.name, fileURL: file.fileURL, byteCount: file.byteCount)
            } else if file.kind == .image, let fileURL = file.fileURL {
                appendOptimizedImage(fileURL: fileURL, name: file.name, byteCount: file.byteCount)
            } else {
                attachments.append(file)
                readVideo(file)
            }
        }
    }


    private func appendOptimizedImage(_ data: Data, name: String, fileURL: URL? = nil, byteCount: Int? = nil) {
        let id = UUID().uuidString
        attachments.append(AgentAttachment(id: id, kind: .image, name: name, data: data,
                                           fileURL: fileURL, byteCount: byteCount ?? data.count))
        optimizingImageIDs.insert(id)
        Task {
            let optimized = await AgentImageOptimizer.optimizeAsync(data)
            guard let index = attachments.firstIndex(where: { $0.id == id }) else {
                optimizingImageIDs.remove(id)
                return
            }
            attachments[index].data = optimized
            attachments[index].fileURL = nil
            attachments[index].byteCount = optimized.count
            attachments[index].name = AgentImageOptimizer.filename(attachments[index].name, for: optimized)

            optimizingImageIDs.remove(id)
            // Optimization mutates an attachment in place, so the ID-based change
            // observer does not fire. Reconcile the prestager after the MIME changes.
            syncPreparedAttachments()

        }
    }

    private func appendOptimizedImage(fileURL: URL, name: String, byteCount: Int?) {
        let id = UUID().uuidString
        attachments.append(AgentAttachment(id: id, kind: .image, name: name, fileURL: fileURL, byteCount: byteCount))
        optimizingImageIDs.insert(id)
        Task {
            guard attachments.contains(where: { $0.id == id }) else {
                optimizingImageIDs.remove(id)
                syncPreparedAttachments()
                return
            }
            if let optimized = await AgentImageOptimizer.optimizeAsync(fileURL: fileURL, byteCount: byteCount) {
                guard let finalIndex = attachments.firstIndex(where: { $0.id == id }) else {
                    optimizingImageIDs.remove(id)
                    syncPreparedAttachments()
                    return
                }
                attachments[finalIndex].data = optimized
                attachments[finalIndex].fileURL = nil
                attachments[finalIndex].byteCount = optimized.count
                attachments[finalIndex].name = AgentImageOptimizer.filename(attachments[finalIndex].name, for: optimized)
            }
            optimizingImageIDs.remove(id)
            syncPreparedAttachments()
        }
    }

    /// Bytes held in memory for a picked file up to this size (the prompt
    /// inlines small text files); larger files stream from their URL at send.
    static let inlineFileBytes = 256 << 10

    /// Picked files, and the reason when one can't be attached. Any size: a
    /// small file's bytes are read now (through the picker's security-scoped
    /// URL), a larger one keeps its URL, and each later reader reopens its
    /// scope (`ScopedFile`): the preview while it is open, the upload while it streams.
    static func readFiles(_ urls: [URL]) -> ([AgentAttachment], String?) {
        var files: [AgentAttachment] = []
        var refused: String?
        for url in urls {
            let access = ScopedFile(url).open()
            defer { access.close() }
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
                refused = "Couldn't read \(url.lastPathComponent)."
                continue
            }
            let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
            if isImage {
                if size > inlineFileBytes {
                    files.append(AgentAttachment(kind: .image, name: url.lastPathComponent,
                                                 fileURL: url, byteCount: size))
                    continue
                }
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    refused = "Couldn't read \(url.lastPathComponent)."
                    continue
                }
                files.append(AgentAttachment(kind: .image, name: url.lastPathComponent, data: data,
                                             fileURL: url, byteCount: size))
                continue
            }
            // A video stays by its URL whatever its size: its frames are read from there.
            if size > inlineFileBytes || AgentVideo.isVideoName(url.lastPathComponent) {
                files.append(AgentAttachment(kind: .file, name: url.lastPathComponent, fileURL: url, byteCount: size))
                continue
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                refused = "Couldn't read \(url.lastPathComponent)."
                continue
            }
            files.append(AgentAttachment(kind: .file, name: url.lastPathComponent, data: data))
        }
        return (files, refused)
    }

    /// One card, one row (``ComposerRowLayout``): `+` (and the voice button when it sits left),
    /// the draft or the collapsed placeholder, then the picker, the context ring and Send. A draft
    /// that wraps goes above the same controls. Before 2026-11-23 the text always had a row of its
    /// own over the controls, 96 pt tall at one line with 10 pt between the text and the buttons.
    private var card: some View {
        ComposerCard(lineHeight: UIFont.preferredFont(forTextStyle: .body).lineHeight) {
            // Strip and text share the cap: the field gives the strip its
            // height, and the transcript's inset leaves out what reaches above
            // the field's own height, so no row moves (Leo, 2026-11-23: "simply
            // have it within the top part of the composer. the inner area grows
            // at the top. no shift, nothing.").
            if !collapsed, !attachments.isEmpty || preparingVideos > 0 {
                attachmentStrip
                    .frame(height: ComposerHeightCap.stripHeight, alignment: .top)
            }
        } leading: {
            HStack(spacing: 0) {
                plusMenu
                if voice.placement == .leading { voiceButton }
            }
        } field: {
            if collapsed {
                // One placeholder: the collapsed capsule reads the same as the field it opens.
                Text(placeholder)
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // A 44 pt target that reports one line, so the row reads it as one line.
                    .padding(.vertical, 12)
                    .contentShape(.rect)
                    .padding(.vertical, -12)
                    .onTapGesture { expand() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(placeholder)
                    // The label is the chat's name, so tests find the capsule by this id.
                    .accessibilityIdentifier("agentChat.composer.collapsed")
            } else {
                // Return starts a new line, the send button sends; a hardware
                // keyboard's Return sends, Shift-Return starts a new line.
                ChatComposerField(text: $text, placeholder: placeholder, isFocused: focus, onSend: sendFromKeyboard,
                                  onPasteAttachments: pasteAttachments,
                                  stripReserve: ComposerHeightCap.stripReserve(hasAttachments: !attachments.isEmpty || preparingVideos > 0),
                                  fieldRef: fieldRef,
                                  onLineChange: { store.lineMotionPending = true })
                    .onAppear { if expandRequested { focus.wrappedValue = true } }
            }
        } trailing: {
            HStack(spacing: 4) {
                if !collapsed {
                    if store.currentModelID != nil || !store.models.isEmpty || !store.modes.isEmpty
                        || store.effortOption?.options.isEmpty == false { pickerMenu }
                    if let usage = store.contextUsage { ContextUsageRing(usage: usage) }
                    // RFD 0130: live counters (or an info mark) opening the Session card; off by default.
                    ComposerFooterFactsView(facts: store.footerFacts, mode: .stored(footerFactsMode))
                }
                // Voice mode instead of a dictation mic (the keyboard's own mic still
                // dictates into the field): with no draft, the send circle is the voice
                // button (ChatGPT's composer); while the agent runs it sits beside Stop.
                // Hidden unless turned on in Settings → Composer (Leo, 2026-11-22: "im
                // hiding this by default"); "Left of Field" puts it after +; "Beside
                // Send" keeps it just left of send, which always shows (Claude's and
                // ChatGPT's composers keep voice next to send).
                let voiceInSend = voice.placement == .sendButton
                if primaryState == .empty || primaryState == .stop, voiceInSend { voiceButton }
                if voice.placement.voiceBesideSend { voiceButton }
                if primaryState != .empty || !voiceInSend { primaryButton }
            }
        }
        // The same 48 pt whether collapsed, focused and empty, or holding one line
        // (``ComposerCard``, the terminal's composer too).
        .accessibilityIdentifier("chat.composer.card")
        .padding(.horizontal, collapsed ? 20 : ComposerCardMetrics.horizontalInset)
    }

    private var placeholder: String {
        // A started chat is named by its title, never by the tab's title, which is the first
        // prompt until the chat is named (issue 51331).
        placeholderOverride ?? (store.isNewChat ? "Ask \(store.summary.agentName)" : store.replyPlaceholder)
    }

    /// Expands the capsule, then focuses the field once it exists.
    private func expand() {
        withAnimation(.cmuxMobileSmooth.unlessReduceMotion) { expandRequested = true }
        Task { @MainActor in
            await Task.yield()
            focus.wrappedValue = true
        }
    }

    // MARK: Controls

    private var plusMenu: some View {
        Menu {
            Section {
                if CameraPicker.isAvailable {
                    Button("Camera", systemImage: "camera") { showCamera = true }
                } else {
                    // Simulators and devices without a camera: say why instead of failing on tap.
                    Button {} label: {
                        Label("Camera", systemImage: "camera")
                        Text("No camera on this device")
                    }
                    .disabled(true)
                }
                Button("Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
                Button("Files", systemImage: "paperclip") { showFiles = true }
                Button("Mention a File", systemImage: "at") {
                    text += text.isEmpty || text.last?.isWhitespace == true ? "@" : " @"
                    expand()
                }
            }
            Section {
                if let plan = store.planModeSwitch {
                    Toggle("Plan Mode", systemImage: "checklist", isOn: Binding(
                        get: { plan.isOn(currentModeID: store.currentModeID) },
                        set: { store.setMode(plan.mode(on: $0)) }
                    ))
                }
                if !store.modes.isEmpty {
                    Menu {
                        Picker("Permission mode", selection: Binding(
                            get: { store.currentModeID ?? "" },
                            set: { store.setMode($0) }
                        )) {
                            ForEach(store.modes) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Permission Mode", systemImage: "lock.shield")
                    }
                }
                if !commands.isEmpty {
                    Menu {
                        ForEach(commands) { command in
                            Button {
                                text = "/\(command.name) "
                                focus.wrappedValue = true
                            } label: {
                                Text("/\(command.name)")
                                Text(command.description)
                            }
                        }
                    } label: {
                        Label("Commands", systemImage: "slash.circle")
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(collapsed ? Color.clear : Color.cmuxMobileFill, in: .circle)
                // A 44 pt target around the 36 pt circle; the padding outside the menu
                // keeps the row's layout.
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .padding(-4)
        .accessibilityLabel("Add")
    }

    /// The one picker button after +: its menu holds three nested submenus, the harness with
    /// its models ("Claude > Opus 5.5", as the Mac's model menu nests them), Mode and Effort, each
    /// row naming its current value. The button names the model and, when they fit, the effort.
    private var pickerMenu: some View {
        Menu {
            // The model row is there whenever the agent offers models, even when the current one
            // is not among them (a default the account lacks, D4).
            if store.currentModelID != nil || !store.models.isEmpty { modelSubmenu }
            if !store.modes.isEmpty { modeSubmenu }
            if let effort = store.effortOption, !effort.options.isEmpty { effortSubmenu(effort) }
        } label: {
            // Model and effort when they fit; at large text sizes the model alone.
            ViewThatFits(in: .horizontal) {
                pickerLabel(withEffort: true)
                pickerLabel(withEffort: false)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.leading, 10)
            .padding(.trailing, 12)
            .frame(minHeight: 34)
            .background(Color.cmuxMobileFill, in: .capsule)
            // 44 pt high target around the 34 pt pill.
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .padding(.vertical, -5)
        // Ahead of the Spacer and the context ring: at large text sizes the button keeps its
        // width (its name truncates) instead of being squeezed to nothing.
        .layoutPriority(1)
        // Source order (model, Mode, Effort), not the reversed order of a menu opened near the
        // bottom of the screen.
        .menuOrder(.fixed)
        .accessibilityLabel(store.currentModelName == nil && store.currentModelID == nil ? "Mode" : "Model")
        .accessibilityValue(Text([store.currentModelName ?? store.currentModelID, currentModeName, currentEffortName]
            .compactMap { $0 }.joined(separator: ", ")))
        .accessibilityIdentifier("agentChat.composer.model")
    }

    /// The pill as the Mac's model chip draws it: the harness's mark, the model in full weight, and
    /// the rest quieter. A mode other than the agent's first (Plan, Full access) is a small symbol,
    /// not its name, and the effort a secondary word; a chevron says it opens a menu (issue 51331:
    /// "Opus 5.5 Bypass permissions Medium" read as one long run of words).
    private func pickerLabel(withEffort: Bool) -> some View {
        let hasModel = store.currentModelName != nil || store.currentModelID != nil
        return HStack(spacing: 6) {
            if let family = AgentSenderIcon.family(store.summary.harness),
               AgentBrandCatalog.spec(forAgent: family) != nil {
                AgentBrandMark(agent: family, size: 15, style: .brand)
                    .accessibilityHidden(true)
            }
            Text(store.currentModelName ?? store.currentModelID ?? currentModeName ?? "Model")
            if hasModel, let mode = store.currentModeID, mode != store.modes.first?.id, currentModeName != nil {
                Image(systemName: ACPMode.pillSymbol(mode))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ACPMode.isFullAccess(mode) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
            }
            if withEffort, hasModel, let effort = currentEffortName {
                Text(effort)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "chevron.down")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .fixedSize(horizontal: withEffort, vertical: false)
    }

    /// The harness the chat runs ("Claude", "Codex"): the model submenu's title, as on the Mac.
    private var harnessName: String { store.summary.harnessDisplayName }

    /// The harness as a submenu of its models, with the current model as the row's subtitle.
    /// With no list (only a current model reported) the submenu would be empty, so the row
    /// names the model alone.
    @ViewBuilder private var modelSubmenu: some View {
        if store.models.isEmpty {
            Button {} label: {
                Text(harnessName)
                if let name = store.currentModelName ?? store.currentModelID { Text(name) }
            }
            .disabled(true)
        } else {
            Menu {
                // Checkable toggles (`checkButton`) rather than an inline picker: an inline picker
                // inside a menu section drops the section's header.
                ForEach(store.models) { model in
                    checkButton(model.name, checked: model.id == store.currentModelID) { store.setModel(model.id) }
                }
            } label: {
                // Two texts, no icon: iOS draws the second as the row's subtitle (a Label with
                // an icon drops it).
                Text(harnessName)
                // The model in force, named as the button names it (its id when the list lacks it).
                if let name = store.currentModelName ?? store.currentModelID { Text(name) }
            }
            .menuOrder(.fixed)
            .accessibilityIdentifier("agentChat.composer.model.harness")
        }
    }

    /// ACP `session/set_mode` over the link. The Mac accepts from the phone only the modes that
    /// still ask before running tools, and the harness's Full access mode when this phone's
    /// Full-access setting covers it (`ACPMode.phoneChoices`); a refused one comes back as the
    /// chat's error line.
    private var modeSubmenu: some View {
        Menu {
            ForEach(store.modes) { mode in
                checkButton(mode.name, checked: mode.id == store.currentModeID) { store.setMode(mode.id) }
            }
        } label: {
            Text("Mode")
            if let name = currentModeName { Text(name) }
        }
        // The agent's order.
        .menuOrder(.fixed)
        .accessibilityIdentifier("agentChat.composer.mode")
    }

    /// The agent's thought-level option, always called Effort (an agent may name it "Reasoning").
    private func effortSubmenu(_ effort: ACPConfigOption) -> some View {
        Menu {
            ForEach(effort.options, id: \.value) { option in
                checkButton(option.name ?? option.value, checked: option.value == effort.currentValue) {
                    store.setConfig(effort.id, value: option.value)
                }
            }
        } label: {
            Text("Effort")
            if let name = currentEffortName { Text(name) }
        }
        .menuOrder(.fixed)
        .accessibilityIdentifier("agentChat.composer.effort")
    }

    private var currentEffortName: String? {
        store.effortOption.flatMap { effort in
            effort.options.first { $0.value == effort.currentValue }.map { $0.name ?? $0.value }
        }
    }

    private var currentModeName: String? {
        store.modes.first { $0.id == store.currentModeID }?.name
    }

    /// A menu row checked when it is the value in force. A Toggle, not a Button with a checkmark
    /// image: iOS draws a menu Toggle's own checkmark at every text size, while it drops a row's
    /// image at accessibility sizes (the Effort submenu then showed no check at all). Choosing
    /// the checked row again changes nothing.
    private func checkButton(_ title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { checked }, set: { on in if on { action() } }))
    }

    private enum PrimaryState { case empty, send, stop, queue }

    private var primaryState: PrimaryState {
        if store.isRunning { return hasContent ? .queue : .stop }
        return hasContent ? .send : .empty
    }

    /// Voice mode on this chat: the agent's words read aloud, the user's
    /// speech sent as prompts. On while it runs here; a tap ends it.
    private var voiceButton: some View {
        let source = AgentChatVoiceSource(store: store)
        let active = voice.isActive(source.voiceSourceID)
        return Button {
            voice.toggle(source)
        } label: {
            // Beside Send, send always shows: the waveform is the plain glyph.
            let style = ComposerVoiceStyle(primaryIsVisible: primaryState == .stop || voice.placement.voiceBesideSend,
                                           active: active)
            Image(systemName: "waveform")
                .font(.system(size: style.isFilled ? 15 : 17, weight: style.isFilled ? .semibold : .regular))
                .foregroundStyle(active ? Color.cmuxMobileOnAccent : Color.primary)
                .symbolEffect(.variableColor.iterative, isActive: active)
                .frame(width: 36, height: 36)
                .cmuxMobilePressBackground(style.fillColor, in: .circle)
                .padding(4)
                .contentShape(.circle)
                .padding(-4)
        }
        .buttonStyle(.cmuxPressFillInLabel)
        .accessibilityLabel(active ? "End Voice Mode" : "Voice Mode")
        .accessibilityIdentifier("agentChat.composer.voice")
    }

    private var primaryButton: some View {
        let state = primaryState
        return Button {
            switch state {
            case .stop: store.cancel()
            // A message steers a running turn, as the Mac's Return does. It asks even before the
            // phone hears the turn start; acpmux steers only into a running turn, else runs it next.
            case .send, .queue: send(steer: true)
            case .empty: break
            }
        } label: {
            Image(systemName: state == .stop ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state == .empty ? Color(uiColor: .tertiaryLabel) : Color.cmuxMobileOnSend)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                // The theme's Send color, never a white disk (`Color.cmuxMobileSend`).
                .cmuxMobilePressBackground(state == .empty ? Color.cmuxMobileFill : Color.cmuxMobileSend, in: .circle)
                .overlay {
                    if state == .queue {
                        Circle().strokeBorder(.secondary, lineWidth: 2).padding(-4)
                    }
                }
                // 36 pt drawn, 44 pt to touch.
                .padding(4)
                .contentShape(.circle)
                .padding(-4)
        }
        .buttonStyle(.cmuxPressFillInLabel)
        .disabled(state == .empty || !optimizingImageIDs.isEmpty)
        .animation(.cmuxMobileSnap.unlessReduceMotion, value: state)
        .contextMenu {
            if state == .queue {
                Button("Queue (send after this turn)", systemImage: "text.line.last.and.arrowtriangle.forward") {
                    send(steer: CmuxMobilePreferences.steersMidTurn(queue: true))
                }
                Button("Steer Now (Interrupt)", systemImage: "arrow.uturn.right") { send(steer: true) }
            }
        }
        .accessibilityLabel(state == .stop ? "Stop" : "Send")
        .accessibilityIdentifier("agentChat.composer.send")
    }

    /// A hardware Return: what the send button would do with a draft (never Stop).
    private func sendFromKeyboard() {
        switch primaryState {
        case .send, .queue: send(steer: true)
        case .stop, .empty: break
        }
    }

    private func send(steer: Bool) {
        guard optimizingImageIDs.isEmpty else { return }
        // A cmux command typed alone runs here, as on the Mac; it is never sent to the agent.
        // A cmux command is cmux's whether the menu offers it here or not (the Mac's
        // `composerCommand`): one it can't run now is refused, never sent to the agent.
        if let run = runCmuxCommand, let parsed = CmuxSlashCommand.parse(text) {
            let typed = text
            Task { @MainActor in
                if let refusal = await run(parsed.command, parsed.args) {
                    store.clientError = refusal
                } else if text == typed {
                    text = ""
                }
            }
            return
        }
        #if DEBUG
        LoadFrameProbe.shared?.event("send")
        #endif
        store.send(prompt: text, attachments: attachments, steer: steer, denyingPermission: denyingPermission)
        // A send that glides (`ChatSendMotion`): the field clears and shrinks on the spring the
        // sent bubble glides in on (the transcript's `ChatSendSettle`), as one motion. Otherwise
        // a multi-line draft shrinks to one line on the line motion, with the transcript.
        if ChatSendMotion.current != .off {
            withAnimation(.cmuxMobileSmooth.unlessReduceMotion) {
                text = ""
                attachments = []
            }
        } else {
            withAnimation(ComposerLineMotion.animation.unlessReduceMotion) { text = "" }
            attachments = []
        }
        sendCount += 1
        if CmuxMobilePreferences.dismissKeyboardAfterSend() { focus.wrappedValue = false }
    }

    // MARK: Attachments, queue, slash commands

    private var attachmentStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentThumb(attachment: attachment, open: {
                        preview = FilePreviewRequest(files: attachments.map(\.localFile), startingAt: attachment.id)
                    }) {
                        attachments.removeAll { $0.id == attachment.id }
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
                if preparingVideos > 0 {
                    HStack(spacing: 6) {
                        CmuxSpinner().controlSize(.small)
                        Text(preparingVideos == 1 ? "Preparing video…" : "Preparing \(preparingVideos) videos…")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 56)
                    .background(Color.cmuxMobileFill, in: .rect(cornerRadius: 12, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
        }
        .scrollIndicators(.hidden)
    }

    /// The cmux commands first, then the agent's, an agent command named as a cmux one left
    /// out (the Mac's `mergedCommands`: cmux's runs).
    private var commands: [ACPAvailableCommand] {
        let own = cmuxCommands.map { ACPAvailableCommand(name: $0.name, description: $0.summary, hint: $0.hint) }
        let names = Set(cmuxCommands.map(\.name))
        return own + store.availableCommands.filter { !names.contains($0.name.lowercased()) }
    }

    private var slashMatches: [ACPAvailableCommand] {
        guard text.hasPrefix("/"), !text.contains(" ") else { return [] }
        let query = text.dropFirst().lowercased()
        let commands = commands
        let prefix = commands.filter { $0.name.lowercased().hasPrefix(query) }
        return prefix.isEmpty ? commands.filter { $0.name.lowercased().contains(query) } : prefix
    }

    /// Every matching command, in a list as tall as its rows while they fit between the
    /// ceiling and the composer card, scrolling past that (`SlashSuggestionsBound`).
    private var slashSuggestions: some View {
        let bound = SlashSuggestionsBound(ceiling: suggestionsCeiling, cardTop: cardTop, gap: Self.suggestionsGap)
        return CappedHeightLayout(maxHeight: bound.maxHeight) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(slashMatches) { command in
                        Button {
                            text = "/\(command.name) "
                        } label: {
                            HStack {
                                Text("/\(command.name)").font(.body.monospaced())
                                Text(command.description).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: SlashSuggestionsBound.minRowHeight)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.cmuxPressFill)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .cmuxMobileFloatingGlass(in: .rect(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
    }

    private func mentionMatches(_ mention: ComposerMention) -> [TerminalArtifact] {
        mentionIndex.matches(mention.query, store: store)
    }

    /// `@` file picker (acpmux `MentionMenu`): files this session referenced.
    private func mentionSuggestions(_ mention: ComposerMention) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(mentionMatches(mention)) { artifact in
                Button {
                    text = mention.inserting(artifact.reference, into: text)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: artifact.kind == .directory ? "folder" : "doc.text")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(artifact.name).font(.body.monospaced()).lineLimit(1).layoutPriority(1)
                        Text((artifact.reference as NSString).deletingLastPathComponent).font(.footnote).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.cmuxPressFill)
                .accessibilityLabel(Text("Mention \(artifact.reference)"))
            }
        }
        .cmuxMobileFloatingGlass(in: .rect(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
    }

    /// A video file's frames, read off the main thread, put on its chip once read (a send before
    /// then sends the video as its link alone, as the Mac does after its wait).
    private func readVideo(_ attachment: AgentAttachment) {
        guard attachment.kind == .file, attachment.video == nil, AgentVideo.isVideoName(attachment.name),
              let url = attachment.fileURL else { return }
        Task { @MainActor in
            guard let video = await ComposerVideoReader.read(url),
                  let index = attachments.firstIndex(where: { $0.id == attachment.id }) else { return }
            attachments[index].video = video
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                preparingVideos += 1
                let started = ContinuousClock.now
                let picked = try? await item.loadTransferable(type: PickedMovie.self)
                preparingVideos -= 1
                let elapsed = ContinuousClock.now - started
                PickedMovie.log.info("pick ms=\(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) ok=\(picked != nil)")
                guard let movie = picked else {
                    store.clientError = String(localized: "Couldn't read the video.")
                    continue
                }
                let size = (try? movie.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                let attachment = AgentAttachment(kind: .file, name: movie.url.lastPathComponent, fileURL: movie.url, byteCount: size)
                attachments.append(attachment)
                readVideo(attachment)
                continue
            }
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            appendOptimizedImage(data, name: "Photo")
        }
        photoItems = []
    }
}

/// Messages waiting for the current turn to end, above the composer or the
/// permission bar (so a queued message stays visible when the bar takes the
/// composer's place). The X takes a message back into an empty composer; with a
/// draft there it asks first, and never replaces the draft.
struct QueuedPromptsView: View {
    let store: AgentChatStore
    @Binding var text: String
    /// The X on a message while the composer holds a draft: which one to confirm removing.
    @State private var confirmingRemoval: QueuedPrompt?
    /// Edit queued prompt: which one, and its text while editing.
    @State private var editing: QueuedPrompt?
    @State private var editText = ""

    var body: some View {
        VStack(spacing: 4) {
            if store.queuePaused {
                pausedNote
            }
            ForEach(Array(store.queue.enumerated()), id: \.element.id) { index, item in
                row(item)
                    // The agent pane's queue actions (its wording), on a long press.
                    .contextMenu {
                        Button("Send now", systemImage: "arrow.up.circle") { store.sendQueuedNow(item.id) }
                        Button("Edit queued prompt", systemImage: "pencil") {
                            editText = item.text
                            editing = item
                        }
                        if store.queue.count > 1 {
                            Button("Move up", systemImage: "arrow.up") { store.moveQueued(item.id, by: -1) }
                                .disabled(index == 0)
                            Button("Move down", systemImage: "arrow.down") { store.moveQueued(item.id, by: 1) }
                                .disabled(index == store.queue.count - 1)
                        }
                        Button("Remove queued prompt", systemImage: "xmark", role: .destructive) { store.removeQueued(item.id) }
                    }
                    .accessibilityActions {
                        Button("Send now") { store.sendQueuedNow(item.id) }
                        Button("Edit queued prompt") {
                            editText = item.text
                            editing = item
                        }
                    }
            }
        }
        .padding(.horizontal, 20)
        .alert("Edit queued prompt", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }),
               presenting: editing) { item in
            TextField("Message", text: $editText, axis: .vertical)
                // Prompts are code-like: no capitals (full verify D5); autocorrect stays on, as on every GUI field (Leo, 2026-11-23).
                .textInputAutocapitalization(.never)
            Button("Cancel", role: .cancel) {}
            Button("Save") { store.editQueued(item.id, text: editText) }
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        // The X while a draft is in the composer: the draft stays, so the message is not
        // put back there; it is removed only on a choice here, and can be copied first.
        .confirmationDialog("Remove queued message?",
                            isPresented: Binding(get: { confirmingRemoval != nil }, set: { if !$0 { confirmingRemoval = nil } }),
                            titleVisibility: .visible, presenting: confirmingRemoval) { item in
            Button("Copy and Remove") {
                UIPasteboard.general.string = item.text
                store.removeQueued(item.id)
            }
            Button("Remove", role: .destructive) { store.removeQueued(item.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your draft stays in the composer.")
        }
    }

    /// The Mac's note over a paused queue (ComposerQueue.tsx): why it waits, and Resume, which
    /// lets acpmux run the held messages (`_acpmux/queue_edit {op: resume}`).
    private var pausedNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle.fill").font(.footnote).foregroundStyle(Color.cmuxMobileWarning)
            Text(pausedText).font(.footnote.weight(.semibold)).lineLimit(2)
            Spacer(minLength: 4)
            Button("Resume", systemImage: "play.fill") { store.resumeQueue() }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.cmuxPressFill)
                .frame(minHeight: 44)
                .accessibilityIdentifier("chat.queue.resume")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .cmuxMobileFloatingGlass(in: .capsule)
        .accessibilityElement(children: .contain)
    }

    private var pausedText: String {
        if store.queuePauseReason == "stop" { return String(localized: "Paused after Stop") }
        guard let error = store.turns.last(where: { $0.status == .failed })?.errorText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !error.isEmpty else { return String(localized: "Paused after an error") }
        return String(localized: "Paused after an error: \(error)")
    }

    private func row(_ item: QueuedPrompt) -> some View {
        Group {
                HStack(spacing: 8) {
                    Image(systemName: "clock").font(.footnote).foregroundStyle(.secondary)
                    Text(item.text).font(.subheadline).lineLimit(1)
                    Spacer()
                    Button {
                        if let restored = store.takeBackQueued(item.id, draft: text) {
                            text = restored
                        } else if store.queue.contains(where: { $0.id == item.id }) {
                            confirmingRemoval = item
                        }
                    } label: {
                        Image(systemName: "xmark").font(.footnote.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.cmuxPressFill)
                    .padding(.trailing, -10)
                    .accessibilityLabel("Remove queued message")
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .cmuxMobileFloatingGlass(in: .capsule)
        }
        .accessibilityIdentifier("chat.queued")
    }

}

/// 56 x 56 thumbnail (images) or a 56 h chip (files) with an X badge. A tap
/// opens it (`open`) full screen.
struct AttachmentThumb: View {
    let attachment: AgentAttachment
    /// Opens the attachment's preview.
    var open: (() -> Void)?
    /// nil: a sent attachment (no remove badge).
    var remove: (() -> Void)?
    /// The thumbnail decoded off the main thread (`SentAttachmentThumbnails`).
    @State private var decoded: UIImage?

    /// Pixels on the short side the 56 pt square is decoded at (3x).
    static let side = SentAttachmentThumbnails.side(CGSize(width: 56, height: 56))

    /// The decoded thumbnail, if one is in memory. Not a decode: `body` runs on every keystroke in
    /// the composer, and a full-size `UIImage(data:)` here decoded the whole photo each time.
    private var image: UIImage? {
        decoded ?? attachment.data.flatMap { SentAttachmentThumbnails.shared.image(attachment, data: $0, side: Self.side) }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.kind == .image, let image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56)
                } else if attachment.kind == .image {
                    // Neutral, as a sent image's placeholder (`SentAttachments`): decoding, or no bytes.
                    Color.cmuxMobileFill
                        .overlay { Image(systemName: "photo").font(.title3).foregroundStyle(.secondary) }
                        .frame(width: 56, height: 56)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: AgentVideo.isVideoName(attachment.name) ? "film" : attachment.isPDF ? "doc.richtext" : "doc.text")
                            .font(.title3)
                        Text(attachment.name).font(.footnote).lineLimit(2).frame(maxWidth: 110, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 56)
                    .background(Color.cmuxMobileFill)
                }
            }
            .clipShape(.rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
            .onTapGesture { open?() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(attachment.kind == .image ? "Image, \(attachment.name)" : attachment.name))
            .accessibilityAddTraits(open == nil ? [] : .isButton)
            .accessibilityHint(open == nil ? "" : "Opens a preview")
            .accessibilityIdentifier("attachment.thumb")
            .task(id: "\(attachment.id)|\(attachment.data?.count ?? 0)") {
                decoded = nil
                guard attachment.kind == .image, let data = attachment.data else { return }
                decoded = await SentAttachmentThumbnails.shared.decode(attachment, data: data, side: Self.side)
            }
            if let remove {
                Button(action: remove) {
                    // Opaque, ringed badge (as in Messages): readable over any thumbnail.
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .cmuxMobilePressBackground(Color(white: 0.18), in: .circle)
                        .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.5))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.cmuxPressFillInLabel)
                .offset(x: 17, y: -17)
                .accessibilityLabel("Remove attachment")
            }
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }
}
/// UIImagePickerController's camera (SwiftUI has no camera picker).
struct CameraPicker: UIViewControllerRepresentable {
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
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
extension ComposerVoiceStyle {
    var fillColor: Color {
        switch fill {
        case .accent: .cmuxMobileAccent
        case .neutral: .cmuxMobileFill
        case .plain: .clear
        }
    }
}
#endif

/// `@` mention candidates, memoized: `SessionArtifacts.collect` walks the whole transcript,
/// and the composer's body asked for it twice on every key while a mention was typed.
/// The artifacts come from `AgentChatStore.mentionArtifacts`, which reads the transcript
/// untracked (frames streaming in never re-render the composer) and rescans at most once a
/// second; the candidates rerun only when the query or the artifacts change. Not observed:
/// it is a cache, read in `body`.
@MainActor
final class MentionIndex {
    private var generation: Int?
    private var lastQuery: String?
    private var lastMatches: [TerminalArtifact] = []

    func matches(_ query: String, store: AgentChatStore) -> [TerminalArtifact] {
        let current = store.mentionArtifacts()
        if generation != current.generation || lastQuery != query {
            generation = current.generation
            lastQuery = query
            lastMatches = ComposerMention.candidates(query, in: current.artifacts)
        }
        return lastMatches
    }
}
