import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileShell
import PhotosUI
import SwiftUI

/// ChatGPT-style mobile conversation surface for Claude, Codex, and OpenCode.
///
/// The list and transcript intentionally live in one destination so the same
/// UI works on iPhone and iPad. On a regular-width device the split view keeps
/// the session picker visible; on a compact device SwiftUI collapses it into a
/// push navigation stack.
struct MobileChatRootView: View {
    @State private var store: MobileChatStore
    @State private var selectedPhotos: [PhotosPickerItem] = []
    let showSettings: () -> Void

    init(
        sourceProvider: @escaping MobileChatStore.SourceProvider,
        showSettings: @escaping () -> Void = {}
    ) {
        _store = State(initialValue: MobileChatStore(sourceProvider: sourceProvider))
        self.showSettings = showSettings
    }

    var body: some View {
        NavigationSplitView {
            sessionList
                .navigationTitle("Chats")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: store.refresh) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh chats")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button(action: store.refresh) {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            Button(action: showSettings) {
                                Label("Chat settings", systemImage: "gearshape")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("Chat options")
                    }
                }
        } detail: {
            transcript
        }
        .task { store.start() }
        .onDisappear { store.stop() }
        .accessibilityIdentifier("MobileAgentChat")
    }

    private var sessionList: some View {
        Group {
            if store.isLoading && store.sessions.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading chats…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.sessions.isEmpty {
                ContentUnavailableView {
                    Label("No agent chats", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(store.errorMessage ?? "Start Claude, Codex, or OpenCode on your Mac to see a chat here.")
                } actions: {
                    Button("Refresh", action: store.refresh)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { store.selectedSessionID },
                    set: { if let value = $0 { store.selectSession(value) } }
                )) {
                    Section {
                        ForEach(store.sessions) { session in
                            Button {
                                store.selectSession(session)
                            } label: {
                                MobileChatSessionRow(
                                    session: session,
                                    isSelected: session.id == store.selectedSessionID
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(
                                session.id == store.selectedSessionID
                                    ? Color.accentColor.opacity(0.13)
                                    : Color.clear
                            )
                            .accessibilityIdentifier("MobileChatSession-\(session.id)")
                        }
                    } header: {
                        Text("Recent")
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if let descriptor = store.selectedSessionID.flatMap({ id in
            store.sessions.first(where: { $0.id == id })
        }) {
            MobileChatTranscriptView(
                store: store,
                descriptor: descriptor,
                selectedPhotos: $selectedPhotos
            )
        } else {
            ContentUnavailableView {
                Label("Choose a chat", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Select a session to view its conversation.")
            }
        }
    }
}

private struct MobileChatSessionRow: View {
    let session: ChatSessionDescriptor
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            MobileChatProviderBadge(kind: session.agentKind, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.title?.isEmpty == false ? session.title! : "New conversation")
                        .font(.headline)
                        .lineLimit(1)
                    if session.state.needsAttention {
                        Circle()
                            .fill(.orange)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Needs input")
                    }
                }
                HStack(spacing: 5) {
                    Text(session.agentKind.displayName)
                    if let directory = session.workingDirectory, !directory.isEmpty {
                        Text("·")
                        Text(URL(fileURLWithPath: directory).lastPathComponent)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            MobileChatStateIndicator(state: session.state)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MobileChatProviderBadge: View {
    let kind: ChatAgentKind
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.16))
            Text(symbol)
                .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(kind.displayName)
    }

    private var symbol: String {
        switch kind {
        case .claude: "C"
        case .codex: "⌘"
        case .openCode: "O"
        case .other: "·"
        }
    }

    private var color: Color {
        switch kind {
        case .claude: Color(red: 0.86, green: 0.42, blue: 0.23)
        case .codex: .green
        case .openCode: .purple
        case .other: .secondary
        }
    }
}

private struct MobileChatStateIndicator: View {
    let state: ChatAgentState

    var body: some View {
        switch state {
        case .working:
            ProgressView().controlSize(.small)
        case .needsInput:
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .idle:
            Circle().fill(.green).frame(width: 7, height: 7)
        case .ended:
            Circle().fill(.tertiary).frame(width: 7, height: 7)
        }
    }
}

private struct MobileChatTranscriptView: View {
    @Bindable var store: MobileChatStore
    let descriptor: ChatSessionDescriptor
    @Binding var selectedPhotos: [PhotosPickerItem]

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.orange.opacity(0.1))
            }
            transcriptBody
            composer
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: descriptor.id) { store.selectSession(descriptor.id) }
        .onChange(of: selectedPhotos) { _, items in
            loadPhotos(items)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            MobileChatProviderBadge(kind: descriptor.agentKind, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(descriptor.title?.isEmpty == false ? descriptor.title! : "Conversation")
                    .font(.headline)
                    .lineLimit(1)
                Text(descriptor.agentKind.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Button("Refresh transcript", systemImage: "arrow.clockwise") {
                    store.selectSession(descriptor.id)
                }
                Button("Stop agent", systemImage: "stop.fill", role: .destructive) {
                    store.interrupt()
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
            }
            .accessibilityLabel("Conversation options")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if store.isLoading && store.messages.isEmpty && store.terminalBlocks.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading transcript…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if store.hasMoreHistory {
                            Button("Load earlier messages") { store.loadOlderHistory() }
                                .font(.footnote.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                        }
                        ForEach(store.messages) { message in
                            MobileChatMessageRow(message: message) { index in
                                store.answer(optionIndex: index)
                            }
                            .id(message.id)
                        }
                        if let preview = store.streamingProse {
                            MobileChatMessageRow(message: preview, isStreaming: true) { index in
                                store.answer(optionIndex: index)
                            }
                            .id("streaming-preview")
                        }
                        ForEach(store.terminalBlocks) { block in
                            MobileChatTerminalBlockRow(block: block)
                                .id("terminal-\(block.id)")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: store.messages.count) { _, _ in
                    if let last = store.messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !store.stagedAttachments.isEmpty {
                HStack {
                    Label("\(store.stagedAttachments.count) image\(store.stagedAttachments.count == 1 ? "" : "s") attached", systemImage: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { store.stagedAttachments = [] }
                        .font(.caption.weight(.semibold))
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $selectedPhotos, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "paperclip")
                        .font(.title3)
                        .frame(width: 34, height: 34)
                }
                .accessibilityLabel("Attach image")
                TextField(
                    descriptor.kind == .terminal ? "Send a command…" : "Message \(descriptor.agentKind.displayName)…",
                    text: $store.draft,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button {
                    store.send()
                } label: {
                    Image(systemName: store.isSending ? "hourglass" : "arrow.up.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .disabled(store.isSending || (store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.stagedAttachments.isEmpty))
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var loaded: [ChatOutboundAttachment] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let format: ChatOutboundAttachment.Format = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? .png : .jpeg
                loaded.append(ChatOutboundAttachment(data: data, format: format))
            }
            await MainActor.run {
                store.stagedAttachments.append(contentsOf: loaded)
                selectedPhotos = []
            }
        }
    }
}

private struct MobileChatMessageRow: View {
    let message: ChatMessage
    var isStreaming = false
    let answer: (Int) -> Void

    var body: some View {
        switch message.kind {
        case .prose(let prose): proseView(prose)
        case .thought(let thought): detailCard("Thought", systemImage: "sparkles", text: thought.text, tint: .purple)
        case .toolUse(let tool): toolView(tool)
        case .terminal(let terminal): terminalView(terminal)
        case .fileEdit(let edit): fileEditView(edit)
        case .permissionRequest(let request): permissionView(request)
        case .question(let question): questionView(question)
        case .status(let status): statusView(status)
        case .attachment(let attachment): attachmentView(attachment)
        case .unsupported(let payload): detailCard("Unsupported content", systemImage: "questionmark.diamond", text: payload.rawType, tint: .secondary)
        }
    }

    @ViewBuilder
    private func proseView(_ prose: ChatProse) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 36)
                Text(verbatim: prose.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let attributed = try? AttributedString(markdown: prose.text) {
                    Text(attributed)
                        .textSelection(.enabled)
                } else {
                    Text(verbatim: prose.text)
                        .textSelection(.enabled)
                }
                if isStreaming {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
        }
    }

    private func toolView(_ tool: ChatToolUse) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: tool.status == .running ? "gearshape.2" : "checkmark.circle")
                    .foregroundStyle(tool.status == .failed ? .red : .secondary)
                Text(tool.toolName).font(.subheadline.weight(.semibold))
                Spacer()
                Text(tool.status.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(tool.summary).font(.subheadline)
            if let output = tool.output, !output.isEmpty {
                Text(verbatim: output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .chatCard(tint: tool.status == .failed ? .red : .secondary)
    }

    private func terminalView(_ terminal: ChatTerminalCapture) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(terminal.command, systemImage: "terminal")
                .font(.subheadline.monospaced().weight(.semibold))
            if let output = terminal.output, !output.isEmpty {
                Text(verbatim: output).font(.caption.monospaced()).textSelection(.enabled)
            }
            if let code = terminal.exitCode {
                Text("Exit \(code)").font(.caption).foregroundStyle(code == 0 ? .green : .red)
            } else if terminal.isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .chatCard(tint: .secondary)
    }

    private func fileEditView(_ edit: ChatFileEdit) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(edit.filePath, systemImage: edit.operation == .delete ? "trash" : "doc.text")
                .font(.subheadline.monospaced().weight(.semibold))
            HStack(spacing: 12) {
                if let additions = edit.additions { Text("+\(additions)").foregroundStyle(.green) }
                if let deletions = edit.deletions { Text("-\(deletions)").foregroundStyle(.red) }
            }
            .font(.caption.monospaced())
            if let diff = edit.unifiedDiff {
                Text(verbatim: diff)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .chatCard(tint: .green)
    }

    private func permissionView(_ request: ChatPermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: request.resolution == nil ? "hand.raised.fill" : "checkmark.seal")
                .font(.headline)
            Text(verbatim: request.subject).font(.subheadline.monospaced())
            if let resolution = request.resolution {
                Text(resolution.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(resolution == .approved ? .green : .secondary)
            } else {
                HStack {
                    Button("Allow") { answer(0) }.buttonStyle(.borderedProminent)
                    Button("Deny", role: .destructive) { answer(1) }.buttonStyle(.bordered)
                }
            }
        }
        .chatCard(tint: .orange)
    }

    private func questionView(_ question: ChatQuestion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Question", systemImage: "questionmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(question.prompt).font(.body)
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button {
                    answer(index)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.label).font(.subheadline.weight(.semibold))
                        if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(question.selectedOptionLabel != nil)
            }
            if let selected = question.selectedOptionLabel {
                Text("Selected: \(selected)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .chatCard(tint: .orange)
    }

    private func statusView(_ status: ChatStatusTransition) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.dotted")
            Text(status.event.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            if let detail = status.detail { Text(detail).foregroundStyle(.secondary) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func attachmentView(_ attachment: ChatAttachment) -> some View {
        Label(attachment.displayName ?? "Attached \(attachment.media.rawValue)", systemImage: attachment.media == .image ? "photo" : "doc")
            .font(.subheadline)
            .chatCard(tint: .blue)
    }

    private func detailCard(
        _ title: String,
        systemImage: String,
        text: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            Text(verbatim: text).font(.subheadline).textSelection(.enabled)
        }
        .chatCard(tint: tint)
    }
}

private struct MobileChatTerminalBlockRow: View {
    let block: TerminalCommandBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(block.command.isEmpty ? "Prompt" : block.command, systemImage: block.isInteractive ? "rectangle.on.rectangle" : "terminal")
                .font(.subheadline.monospaced().weight(.semibold))
            if !block.output.isEmpty { Text(verbatim: block.output).font(.caption.monospaced()).textSelection(.enabled) }
            if let exitCode = block.exitCode { Text("Exit \(exitCode)").font(.caption).foregroundStyle(block.failed ? .red : .green) }
        }
        .chatCard(tint: block.failed ? .red : .secondary)
    }
}

private extension View {
    func chatCard(tint: Color) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tint.opacity(0.22), lineWidth: 1)
            }
    }
}
