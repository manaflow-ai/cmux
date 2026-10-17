import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileShell
import PhotosUI
import SwiftUI
import UIKit

/// ChatGPT-style mobile conversation surface for Claude, Codex, and OpenCode.
///
/// The list and transcript intentionally live in one destination so the same
/// UI works on iPhone and iPad. On a regular-width device the split view keeps
/// the session picker visible; on a compact device SwiftUI collapses it into a
/// push navigation stack.
struct MobileChatRootView: View {
    @State private var store: MobileChatStore
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var showsNewChatSheet = false
    @State private var providerFilter: ChatAgentKind?
    @Environment(\.scenePhase) private var scenePhase
    private let searchText: String
    private let connectionGeneration: UUID
    private let startNewChat: (ChatAgentKind) -> Void
    let showSettings: () -> Void

    init(
        sourceProvider: @escaping MobileChatStore.SourceProvider,
        searchText: String = "",
        connectionGeneration: UUID,
        startNewChat: @escaping (ChatAgentKind) -> Void = { _ in },
        showSettings: @escaping () -> Void = {}
    ) {
        _store = State(initialValue: MobileChatStore(sourceProvider: sourceProvider))
        self.searchText = searchText
        self.connectionGeneration = connectionGeneration
        self.startNewChat = startNewChat
        self.showSettings = showSettings
    }

    var body: some View {
        NavigationSplitView {
            sessionList
                .navigationTitle("Chats")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showsNewChatSheet = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .accessibilityLabel("New chat")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button {
                                showsNewChatSheet = true
                            } label: {
                                Label("New chat", systemImage: "square.and.pencil")
                            }
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
        .task(id: connectionGeneration) { store.restart() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // A live event stream can miss frames while iOS suspends the app.
            // Rebuild both streams on foreground so the authoritative list and
            // selected transcript heal even when the transport identity did not
            // change.
            store.restart()
        }
        .onDisappear { store.stop() }
        .sheet(isPresented: $showsNewChatSheet) {
            MobileNewChatSheet { provider in
                showsNewChatSheet = false
                startNewChat(provider)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(for: String.self) { sessionID in
            transcript(for: sessionID)
        }
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
            } else if filteredSessions.isEmpty {
                if let providerFilter {
                    ContentUnavailableView {
                        Label("No \(providerFilter.displayName) chats", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Try another provider or show all chats.")
                    } actions: {
                        Button("Show all providers") { self.providerFilter = nil }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                VStack(spacing: 0) {
                    if let connectionBannerMessage {
                        Label(connectionBannerMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .background(.orange.opacity(0.1))
                    }
                    List(selection: Binding(
                        get: { store.selectedSessionID },
                        set: { if let value = $0 { store.selectSession(value) } }
                    )) {
                        Section {
                            providerFilterControl
                        }
                        Section {
                            ForEach(filteredSessions) { session in
                                NavigationLink(value: session.id) {
                                    MobileChatSessionRow(
                                        session: session,
                                        isSelected: session.id == store.selectedSessionID
                                    )
                                }
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
    }

    private var connectionBannerMessage: String? {
        if let errorMessage = store.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        guard !store.isConnected, !store.isLoading else { return nil }
        return "Connection lost. Refresh to reconnect."
    }

    private var providerFilterControl: some View {
        Menu {
            Button {
                providerFilter = nil
            } label: {
                Label("All providers", systemImage: providerFilter == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(ChatAgentKind.supportedProviders, id: \.self) { provider in
                Button {
                    providerFilter = provider
                } label: {
                    Label {
                        Text(provider.displayName)
                    } icon: {
                        MobileChatProviderBadge(kind: provider, size: 18)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text(providerFilter?.displayName ?? "All providers")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter chats by provider")
    }

    private var filteredSessions: [ChatSessionDescriptor] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerSessions = providerFilter.map { provider in
            store.sessions.filter { $0.agentKind == provider }
        } ?? store.sessions
        guard !query.isEmpty else { return providerSessions }
        return providerSessions.filter { session in
            [
                session.title,
                session.workingDirectory,
                session.agentKind.displayName,
                session.agentKind.sourceName,
            ]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    @ViewBuilder
    private var transcript: some View {
        transcript(for: store.selectedSessionID)
    }

    @ViewBuilder
    private func transcript(for sessionID: String?) -> some View {
        if let descriptor = sessionID.flatMap({ id in
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
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(kind.displayName)
    }

    private var symbol: String {
        switch kind {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .openCode: "circle.grid.2x2"
        case .other: "ellipsis"
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

private extension ChatAgentKind {
    static let supportedProviders: [Self] = [.codex, .claude, .openCode]

    /// The provider label shown in the compact conversation header. The
    /// transcript protocol intentionally carries provider identity rather than
    /// a model catalog, so this stays honest while still making the active
    /// runtime visible at a glance.
    var modelDisplayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .other: displayName
        }
    }

    var launchCommand: String? {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .openCode: "opencode"
        case .other: nil
        }
    }
}

private struct MobileNewChatSheet: View {
    @State private var provider: ChatAgentKind = .codex
    let start: (ChatAgentKind) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Start a new chat")
                            .font(.title2.weight(.bold))
                        Text("Choose the coding agent to run in a new workspace on your connected Mac.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 12, trailing: 0))
                    .listRowBackground(Color.clear)
                }

                Section("Provider") {
                    ForEach(ChatAgentKind.supportedProviders, id: \.self) { candidate in
                        Button {
                            provider = candidate
                        } label: {
                            HStack(spacing: 12) {
                                MobileChatProviderBadge(kind: candidate, size: 40)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.displayName)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(candidate.modelDisplayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: provider == candidate ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(provider == candidate ? Color.accentColor : Color.secondary)
                                    .font(.title3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(provider == candidate ? .isSelected : [])
                    }
                }

                Section {
                    Button {
                        start(provider)
                    } label: {
                        Label("Start \(provider.displayName) chat", systemImage: "arrow.up.right.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(provider.launchCommand == nil)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
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

private extension ChatAgentState {
    var label: String {
        switch self {
        case .working: "Working"
        case .needsInput: "Needs input"
        case .idle: "Ready"
        case .ended: "Ended"
        }
    }
}

private struct MobileChatWelcomeView: View {
    let provider: ChatAgentKind
    let sendSuggestion: (String) -> Void

    private let suggestions = [
        "Inspect this repository",
        "Fix a failing test",
        "Explain this project",
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 44)
                MobileChatProviderBadge(kind: provider, size: 58)
                VStack(spacing: 7) {
                    Text("What can I help you build?")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text("\(provider.modelDisplayName) is ready in this conversation.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 10) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            sendSuggestion(suggestion)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: suggestion == suggestions[0] ? "magnifyingglass" : suggestion == suggestions[1] ? "wrench.and.screwdriver" : "text.book.closed")
                                    .foregroundStyle(.secondary)
                                Text(suggestion)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: "arrow.up.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(.background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(.quaternary, lineWidth: 0.8)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 420)
                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, minHeight: 340)
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }
}

private struct MobileChatTranscriptView: View {
    @Bindable var store: MobileChatStore
    let descriptor: ChatSessionDescriptor
    @Binding var selectedPhotos: [PhotosPickerItem]
    @FocusState private var composerFocused: Bool

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
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
        }
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
                HStack(spacing: 5) {
                    Text(descriptor.agentKind.modelDisplayName)
                    Text("·")
                    Text(descriptor.state.label)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if case .working = descriptor.state {
                ProgressView().controlSize(.small)
            } else if descriptor.state.needsAttention {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Needs your input")
            }
            Menu {
                Button("Refresh transcript", systemImage: "arrow.clockwise") {
                    store.refreshTranscript()
                }
                Button("Stop agent", systemImage: "stop.fill", role: .destructive) {
                    store.interrupt()
                }
                .disabled(descriptor.state == .ended)
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
        } else if store.messages.isEmpty && store.terminalBlocks.isEmpty && store.streamingProse == nil {
            MobileChatWelcomeView(
                provider: descriptor.agentKind,
                sendSuggestion: { suggestion in
                    guard descriptor.state != .ended else { return }
                    store.draft = suggestion
                    composerFocused = true
                }
            )
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
                            MobileChatMessageRow(
                                message: message,
                                provider: descriptor.agentKind,
                                allowsInteraction: descriptor.state != .ended
                            ) { index in
                                store.answer(optionIndex: index)
                            }
                            .id(message.id)
                        }
                        if let preview = store.streamingProse {
                            MobileChatMessageRow(
                                message: preview,
                                provider: descriptor.agentKind,
                                isStreaming: true,
                                allowsInteraction: descriptor.state != .ended
                            ) { index in
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
                .scrollDismissesKeyboard(.interactively)
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
            if descriptor.state == .ended {
                Label("This agent session has ended", systemImage: "clock.badge.checkmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9)
                    .accessibilityLabel("This agent session has ended. Messaging is unavailable.")
            } else {
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
                        Image(systemName: "plus")
                            .font(.headline.weight(.semibold))
                            .frame(width: 34, height: 34)
                            .background(.quaternary, in: Circle())
                    }
                    .accessibilityLabel("Add attachment")
                    TextField(
                        descriptor.kind == .terminal ? "Send a command…" : "Message \(descriptor.agentKind.displayName)…",
                        text: $store.draft,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .focused($composerFocused)
                    .background(.background, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 0.8)
                    }
                    Button {
                        store.send()
                        composerFocused = false
                    } label: {
                        Image(systemName: store.isSending ? "hourglass" : "arrow.up.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .disabled(store.isSending || (store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.stagedAttachments.isEmpty))
                    .accessibilityLabel("Send message")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.quaternary)
                .frame(height: 0.5)
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let sessionID = descriptor.id
        Task {
            var loaded: [ChatOutboundAttachment] = []
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let format: ChatOutboundAttachment.Format = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? .png : .jpeg
                loaded.append(ChatOutboundAttachment(data: data, format: format))
            }
            await MainActor.run {
                selectedPhotos = []
                // Photo decoding may finish after the user changes chats. Do
                // not attach the old pick to whichever session happens to be
                // selected when the asynchronous load completes.
                guard store.selectedSessionID == sessionID else { return }
                store.stagedAttachments.append(contentsOf: loaded)
            }
        }
    }
}

private struct MobileChatMessageRow: View {
    let message: ChatMessage
    let provider: ChatAgentKind
    var isStreaming = false
    var allowsInteraction = true
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
            HStack(alignment: .top, spacing: 10) {
                MobileChatProviderBadge(kind: provider, size: 26)
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
            if let input = tool.inputDetail, !input.isEmpty {
                DisclosureGroup("Details") {
                    Text(verbatim: input)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.weight(.semibold))
            }
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
                    Button("Allow") { answer(0) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!allowsInteraction)
                    Button("Deny", role: .destructive) { answer(1) }
                        .buttonStyle(.bordered)
                        .disabled(!allowsInteraction)
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
                .disabled(question.selectedOptionLabel != nil || !allowsInteraction)
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
