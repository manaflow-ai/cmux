#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileDesign
import CmuxMobileTransport
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// SPEC 4.3 composer for agent chat: glass card with a text row over a
/// controls row (`+` menu, model pill, mic, send/stop), attachment previews,
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
    /// Replaces "Reply to <agent>" (e.g. while replying instead of a permission).
    var placeholderOverride: String?
    /// Sending answers the pending permission with a denial plus this message.
    var denyingPermission = false
    /// Window y the slash-command list may not rise above (under the chat's header and
    /// what the bottom stack shows over the composer); nil when the host does not say.
    var suggestionsCeiling: CGFloat?
    /// A Retry uses the same send path, including queue/steer and draft clearing.
    var retryCount = 0
    /// The cmux commands this chat offers (`/status`, `/fork`, `/continue`), listed before the
    /// agent's own, and what runs one when it is sent alone: nil when it ran, else the refusal
    /// shown over the composer (the draft stays). Empty: none offered.
    var cmuxCommands: [CmuxSlashCommand] = []
    var runCmuxCommand: (@MainActor (CmuxSlashCommand, String) async -> String?)?
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
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
    /// The slash-command list's bottom edge, window y (its height bound's floor).
    @State private var suggestionsBottom: CGFloat?

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasContent: Bool { !trimmed.isEmpty || !attachments.isEmpty }
    private var collapsedTarget: Bool { collapsible && !focus.wrappedValue && !hasContent && !expandRequested }
    /// Follows `collapsedTarget` inside an explicit `.cmuxMobileSmooth` animation.
    /// Losing focus to the keyboard's dismissal changes the target in an
    /// update that carries no animation, and the capsule snapped shut while
    /// the transcript above it eased down (verify/keyboard.md).
    @State private var shownCollapsed: Bool?
    private var collapsed: Bool { shownCollapsed ?? collapsedTarget }
    /// `collapsible` as last placed: it flips when the chat's first turns come.
    @State private var placedCollapsible: Bool?

    var body: some View {
        VStack(spacing: 8) {
            if !slashMatches.isEmpty {
                slashSuggestions
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let mention = ComposerMention(text: text), !mentionMatches(mention).isEmpty {
                mentionSuggestions(mention)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            card
        }
        .animation(.cmuxMobileSmooth, value: collapsed)
        .animation(.cmuxMobileSnappy, value: attachments)
        .filePreview($preview)
        // Photos and videos, as the Mac's composer takes both (a video goes with its frames).
        .photosPicker(isPresented: $showPhotos, selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let (files, refused) = Self.readFiles(urls)
                attachments += files
                for file in files { readVideo(file) }
                if let refused { store.clientError = refused }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.85) {
                    attachments.append(AgentAttachment(kind: .image, name: "Camera \(Date().formatted(date: .omitted, time: .shortened))", data: data))
                }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await loadPhotos(items) }
        }
        .cmuxMobileSensoryFeedback(.impact(weight: .light), trigger: sendCount)
        .onChange(of: retryCount) { _, _ in sendFromKeyboard() }
        .onChange(of: focus.wrappedValue) { _, focused in
            if focused { expandRequested = false }
        }
        .onAppear { if expandOnAppear { expand() } }
        #if DEBUG
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: "-cmux-mobile-demo"),
                  arguments.indices.contains(index + 1), arguments[index + 1] == "offline-send",
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
        // A prompt that never reached the agent comes back to the composer.
        .onChange(of: store.returnedDraft) { _, draft in
            guard let draft else { return }
            store.returnedDraft = nil
            if trimmed.isEmpty { text = draft.text }
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
                withAnimation(.cmuxMobileSmooth) { shownCollapsed = target }
            }
        }
    }

    /// A copied image or file pasted into the field: attached as Photos or
    /// Files would attach it (`UIPasteboard.composerImages`).
    private func pasteAttachments() {
        let board = UIPasteboard.general
        if board.hasImages {
            let stamp = Date().formatted(date: .omitted, time: .shortened)
            for (index, image) in board.composerImages().enumerated() {
                let suffix = index > 0 ? " \(index + 1)" : ""
                attachments.append(AgentAttachment(kind: .image, name: "Pasted image \(stamp)\(suffix)", data: image.data))
            }
        } else if board.composerHoldsFileData {
            // A file copied in Files is its bytes on the pasteboard, not a path.
            let providers = board.itemProviders
            Task {
                let pasted = await ComposerPastedFiles.load(providers)
                attachments += pasted.files.map { file in
                    let image = file.type.conforms(to: .image) ? file.data.flatMap { UIImage(data: $0) } : nil
                    return AgentAttachment(kind: image == nil ? .file : .image, name: file.name,
                                           data: file.data, fileURL: file.fileURL, byteCount: file.byteCount)
                }
                if let name = pasted.unreadable.first { store.clientError = "Couldn't read \(name)." }
            }
        } else if let urls = board.urls?.filter(\.isFileURL), !urls.isEmpty {
            let (files, refused) = Self.readFiles(urls)
            attachments += files
            if let refused { store.clientError = refused }
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
            if size > inlineFileBytes {
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

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !collapsed {
                if !attachments.isEmpty {
                    attachmentStrip
                }
                // Return starts a new line, the send button sends; a hardware
                // keyboard's Return sends, Shift-Return starts a new line.
                ChatComposerField(text: $text, placeholder: placeholder, isFocused: focus, onSend: sendFromKeyboard,
                                  onPasteAttachments: pasteAttachments)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                    .onAppear { if expandRequested { focus.wrappedValue = true } }
            }
            HStack(spacing: 8) {
                plusMenu
                if collapsed {
                    // One placeholder: the collapsed capsule reads the same as the field it opens.
                    Text(placeholder)
                        .lineLimit(1)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture { expand() }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(placeholder)
                } else {
                    // The menu is there whenever the agent offers models, even when the
                    // current one is not among them (a default the account lacks, D4).
                    if store.currentModelName != nil || !store.models.isEmpty || !store.modes.isEmpty { modelPill }
                    Spacer(minLength: 0)
                    if let usage = store.contextUsage { ContextUsageRing(usage: usage) }
                }
                // No mic button: iOS has no API to start keyboard dictation, and the
                // keyboard's own mic dictates into this field (SPEC open decision).
                primaryButton
            }
            .padding(.horizontal, 8)
            .padding(.bottom, collapsed ? 6 : 8)
            .padding(.top, collapsed ? 6 : 0)
        }
        .frame(minHeight: collapsed ? 48 : 96, alignment: .bottom)
        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, collapsed ? 20 : 12)
    }

    private var placeholder: String {
        placeholderOverride ?? (!store.hasTurns ? "Ask \(store.summary.agentName)" : "Reply to \(store.summary.agentName)")
    }

    /// Expands the capsule, then focuses the field once it exists.
    private func expand() {
        withAnimation(.cmuxMobileSmooth) { expandRequested = true }
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

    private var modelPill: some View {
        Menu {
            // Checkmark buttons rather than inline pickers: an inline picker
            // inside a menu section drops the section's header.
            if !store.models.isEmpty {
                Section("Model") {
                    ForEach(store.models) { model in
                        checkButton(model.name, checked: model.id == store.currentModelID) { store.setModel(model.id) }
                    }
                }
            }
            // ACP `session/set_mode` over the link. The Mac accepts from the phone only the
            // modes that still ask before running tools, and the harness's Full access mode
            // when this phone's Full-access setting covers it (`ACPMode.phoneChoices`); a
            // refused one comes back as the chat's error line.
            if !store.modes.isEmpty {
                Section("Mode") {
                    ForEach(store.modes) { mode in
                        checkButton(mode.name, checked: mode.id == store.currentModeID) { store.setMode(mode.id) }
                    }
                }
            }
            if let effort = store.effortOption {
                Section(effort.name ?? "Effort") {
                    ForEach(effort.options, id: \.value) { option in
                        checkButton(option.name ?? option.value, checked: option.value == effort.currentValue) {
                            store.setConfig(effort.id, value: option.value)
                        }
                    }
                }
            }
        } label: {
            // Model and effort when they fit; at large text sizes the model alone.
            ViewThatFits(in: .horizontal) {
                modelPillLabel(withEffort: true)
                modelPillLabel(withEffort: false)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minHeight: 34)
            .background(Color.cmuxMobileFill, in: .capsule)
            // 44 pt high target around the 34 pt pill.
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .padding(.vertical, -5)
        // Source order (Model, Mode, Effort; modes in the agent's order), the same as the
        // title menu, not the reversed order of a menu opened near the bottom of the screen.
        .menuOrder(.fixed)
        .accessibilityLabel(store.currentModelName == nil ? "Mode" : "Model")
        .accessibilityValue(Text([store.currentModelName, store.effortOption.flatMap { effort in
            effort.options.first { $0.value == effort.currentValue }.map { $0.name ?? $0.value }
        }].compactMap { $0 }.joined(separator: ", ")))
    }

    private func modelPillLabel(withEffort: Bool) -> some View {
        HStack(spacing: 4) {
            Text(store.currentModelName ?? store.currentModelID ?? currentModeName ?? "Model")
            if withEffort, store.currentModelName != nil, let mode = currentModeName, store.currentModeID != store.modes.first?.id {
                Text(mode).foregroundStyle(.secondary)
            }
            if withEffort, let effort = store.effortOption, let value = effort.options.first(where: { $0.value == effort.currentValue }) {
                Text(value.name ?? value.value).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: withEffort, vertical: false)
    }

    private var currentModeName: String? {
        store.modes.first { $0.id == store.currentModeID }?.name
    }

    private func checkButton(_ title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if checked {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private enum PrimaryState { case empty, send, stop, queue }

    private var primaryState: PrimaryState {
        if store.isRunning { return hasContent ? .queue : .stop }
        return hasContent ? .send : .empty
    }

    private var primaryButton: some View {
        let state = primaryState
        return Button {
            switch state {
            case .stop: store.cancel()
            // A follow-up while the agent works queues, or steers it when Settings says so.
            case .send, .queue: send(steer: state == .queue && CmuxMobilePreferences.steersFollowUps())
            case .empty: break
            }
        } label: {
            Image(systemName: state == .stop ? "stop.fill" : "arrow.up")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state == .empty ? Color(uiColor: .tertiaryLabel) : Color.cmuxMobileOnAccent)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 36, height: 36)
                .background(state == .empty ? Color.cmuxMobileFill : Color.cmuxMobileAccent, in: .circle)
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
        .buttonStyle(.plain)
        .disabled(state == .empty)
        .animation(.cmuxMobileSnap, value: state)
        .contextMenu {
            if state == .queue {
                Button("Queue (send after this turn)", systemImage: "text.line.last.and.arrowtriangle.forward") { send(steer: false) }
                Button("Steer Now (Interrupt)", systemImage: "arrow.uturn.right") { send(steer: true) }
            }
        }
        .accessibilityLabel(state == .stop ? "Stop" : "Send")
    }

    /// A hardware Return: what the send button would do with a draft (never Stop).
    private func sendFromKeyboard() {
        switch primaryState {
        case .send: send(steer: false)
        case .queue: send(steer: CmuxMobilePreferences.steersFollowUps())
        case .stop, .empty: break
        }
    }

    private func send(steer: Bool) {
        // A cmux command typed alone runs here, as on the Mac; it is never sent to the agent.
        if attachments.isEmpty, let run = runCmuxCommand, let (command, args) = CmuxSlashCommand.parse(text),
           cmuxCommands.contains(command) {
            let typed = text
            Task { @MainActor in
                if let refusal = await run(command, args) {
                    store.clientError = refusal
                } else if text == typed {
                    text = ""
                }
            }
            return
        }
        store.send(prompt: text, attachments: attachments, steer: steer, denyingPermission: denyingPermission)
        text = ""
        attachments = []
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
        let bound = SlashSuggestionsBound(ceiling: suggestionsCeiling, bottom: suggestionsBottom)
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
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        // The card's top, which only the keyboard or the resting place moves (the
        // stack is bottom-aligned), so the list's own height never feeds back here.
        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .global).maxY }) { bottom in
            if suggestionsBottom != bottom { suggestionsBottom = bottom }
        }
        .padding(.horizontal, 12)
    }

    private func mentionMatches(_ mention: ComposerMention) -> [TerminalArtifact] {
        let collected = SessionArtifacts.collect(turns: store.turns, subagents: store.subagents, cwd: store.summary.cwd)
        return ComposerMention.candidates(mention.query, in: collected.artifacts)
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
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Mention \(artifact.reference)"))
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
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
                guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
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
            var attachment = AgentAttachment(kind: .image, name: "Photo", data: data)
            // HEIC and other formats agents do not accept go over as JPEG.
            if attachment.imageMIMEType == nil, let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) {
                attachment.data = jpeg
            }
            attachments.append(attachment)
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
                // Prompts are code-like: no autocorrect, no capitals (full verify D5).
                .autocorrectionDisabled()
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
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityIdentifier("chat.queue.resume")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
        .glassEffect(.regular, in: .capsule)
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
                    .buttonStyle(.plain)
                    .padding(.trailing, -10)
                    .accessibilityLabel("Remove queued message")
                }
                .padding(.horizontal, 14)
                .frame(height: 40)
                .glassEffect(.regular, in: .capsule)
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.kind == .image, let data = attachment.data, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: 56, height: 56)
                } else if attachment.kind == .image {
                    LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay { Image(systemName: "photo").foregroundStyle(.white) }
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
            if let remove {
                Button(action: remove) {
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
#endif
