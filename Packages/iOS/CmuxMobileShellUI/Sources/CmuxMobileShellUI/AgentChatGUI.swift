import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import Observation
import SwiftUI

#if os(iOS)

/// The native agent workspace.  This is deliberately independent from Feed:
/// Feed is a cross-machine activity inbox, while this surface is a focused,
/// ChatGPT-style conversation with one coding agent session.
struct AgentChatRootView: View {
    let source: MobileChatEventSource?

    var body: some View {
        Group {
            if let source {
                AgentChatSessionListView(source: source)
            } else {
                ContentUnavailableView(
                    "Agents unavailable",
                    systemImage: "bubble.left.and.exclamationmark.bubble.right",
                    description: Text("Connect a computer running cmux to open a coding-agent conversation.")
                )
            }
        }
        .tint(.accentColor)
        .overlay { MobileReplayPrivacyMask().allowsHitTesting(false) }
    }
}

@MainActor
@Observable
private final class AgentChatSessionListStore {
    let source: MobileChatEventSource
    var sessions: [ChatSessionDescriptor] = []
    var selectedProvider: ChatAgentKind?
    var isLoading = false
    var errorMessage: String?

    init(source: MobileChatEventSource) {
        self.source = source
    }

    var visibleSessions: [ChatSessionDescriptor] {
        let filtered = selectedProvider.map { provider in
            sessions.filter { $0.agentKind == provider }
        } ?? sessions
        return ChatSessionDescriptor.openable(filtered)
    }

    func refresh() async {
        isLoading = sessions.isEmpty
        do {
            sessions = try await source.sessions(workspaceID: nil)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t load agent sessions."
        }
        isLoading = false
    }

    func startEvents() async {
        for await frame in await source.sessionEvents() {
            switch frame.event {
            case .descriptorChanged(let descriptor): upsert(descriptor)
            case .stateChanged(let state):
                if let index = sessions.firstIndex(where: { $0.id == frame.sessionID }) {
                    sessions[index] = sessions[index].withState(state)
                }
            case .sessionRemoved:
                sessions.removeAll { $0.id == frame.sessionID }
            default: break
            }
        }
    }

    private func upsert(_ descriptor: ChatSessionDescriptor) {
        if let index = sessions.firstIndex(where: { $0.id == descriptor.id }) {
            guard descriptor.version >= sessions[index].version else { return }
            sessions[index] = descriptor
        } else {
            sessions.append(descriptor)
        }
    }
}

private struct AgentChatSessionListView: View {
    @State private var model: AgentChatSessionListStore
    @State private var selectedSession: ChatSessionDescriptor?

    init(source: MobileChatEventSource) {
        _model = State(initialValue: AgentChatSessionListStore(source: source))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.sessions.isEmpty {
                    ProgressView("Loading agents…")
                } else if model.visibleSessions.isEmpty {
                    ContentUnavailableView(
                        "No agent conversations",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("Start Claude, Codex, or OpenCode in a cmux terminal and it will appear here.")
                    )
                } else {
                    List(model.visibleSessions) { session in
                        Button {
                            selectedSession = session
                        } label: {
                            AgentChatSessionRow(session: session)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("AgentChatSession-\(session.id)")
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Agents")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("All agents") { model.selectedProvider = nil }
                        ForEach([ChatAgentKind.claude, .codex, .opencode], id: \.sourceName) { provider in
                            Button(provider.displayName) { model.selectedProvider = provider }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filter agents")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await model.refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(model.isLoading)
                    .accessibilityLabel("Refresh agent sessions")
                }
            }
            .refreshable { await model.refresh() }
            .task {
                await model.refresh()
                await model.startEvents()
            }
            .navigationDestination(isPresented: Binding(
                get: { selectedSession != nil },
                set: { if !$0 { selectedSession = nil } }
            )) {
                if let selectedSession {
                    AgentChatConversationView(source: model.source, session: selectedSession)
                }
            }
            .alert("Agents", isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }
}

private struct AgentChatSessionRow: View {
    let session: ChatSessionDescriptor

    var body: some View {
        HStack(spacing: 14) {
            AgentChatProviderMark(provider: session.agentKind)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(session.title?.isEmpty == false ? session.title! : "New conversation")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    Text(session.lastActivityAt ?? .distantPast, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(session.agentKind.displayName)
                        .font(.subheadline.weight(.medium))
                    Text("·")
                    Text(session.workingDirectory ?? "cmux terminal")
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                AgentChatStateLabel(state: session.state)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct AgentChatConversationView: View {
    @State private var model: AgentChatConversationStore

    init(source: MobileChatEventSource, session: ChatSessionDescriptor) {
        _model = State(initialValue: AgentChatConversationStore(source: source, session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.hasMore {
                            Button("Load earlier messages") {
                                Task { await model.loadEarlier() }
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        }
                        ForEach(model.messages) { message in
                            AgentChatMessageCell(message: message, answer: { index in
                                Task { await model.answer(optionIndex: index) }
                            })
                            .id(message.id)
                        }
                        if let streaming = model.streamingProse {
                            AgentChatBubble(role: .agent, text: streaming)
                                .id("streaming")
                        }
                        if case .working = model.session.state {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Working…").foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 6)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 20)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages.count) { _, _ in
                    guard let id = model.messages.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: model.streamingProse) { _, value in
                    guard value != nil else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("streaming", anchor: .bottom) }
                }
            }
            AgentChatComposer(model: model)
        }
        .navigationTitle(model.session.title?.isEmpty == false ? model.session.title! : model.session.agentKind.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if case .working = model.session.state {
                    Button(role: .destructive) { Task { await model.interrupt() } } label: {
                        Image(systemName: "stop.circle.fill")
                    }
                    .accessibilityLabel("Stop agent")
                }
            }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
    }
}

@MainActor
@Observable
private final class AgentChatConversationStore {
    let source: MobileChatEventSource
    var session: ChatSessionDescriptor
    var messages: [ChatMessage] = []
    var streamingProse: String?
    var hasMore = false
    var draft = ""
    var isSending = false
    var errorMessage: String?
    private var streamTask: Task<Void, Never>?

    init(source: MobileChatEventSource, session: ChatSessionDescriptor) {
        self.source = source
        self.session = session
    }

    func start() async {
        await loadLatest()
        stop()
        streamTask = Task { [source, sessionID = session.id] in
            for await event in await source.events(sessionID: sessionID) {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in self?.apply(event) }
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    func loadLatest() async {
        do {
            let page = try await source.history(sessionID: session.id, beforeSeq: nil, limit: 100)
            messages = page.messages
            hasMore = page.hasMore
        } catch {
            errorMessage = "Couldn’t load this conversation."
        }
    }

    func loadEarlier() async {
        guard let before = messages.first?.seq, hasMore else { return }
        do {
            let page = try await source.history(sessionID: session.id, beforeSeq: before, limit: 100)
            let existing = Set(messages.map(\.id))
            messages = page.messages.filter { !existing.contains($0.id) } + messages
            hasMore = page.hasMore
        } catch { errorMessage = "Couldn’t load earlier messages." }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        isSending = true
        do {
            try await source.send(text: text, attachments: [], sessionID: session.id)
            draft = ""
        } catch { errorMessage = "Your message wasn’t sent." }
        isSending = false
    }

    func interrupt() async {
        try? await source.interrupt(sessionID: session.id, hard: false)
    }

    func answer(optionIndex: Int) async {
        try? await source.answer(optionIndex: optionIndex, sessionID: session.id)
    }

    private func apply(_ event: ChatSessionEvent) {
        switch event {
        case .appended(let newMessages):
            upsert(newMessages)
            streamingProse = nil
        case .updated(let updates): upsert(updates)
        case .stateChanged(let state): session = session.withState(state)
        case .descriptorChanged(let descriptor):
            guard descriptor.version >= session.version else { return }
            session = descriptor
        case .streamingProse(let preview): streamingProse = preview.flatMap { message in
            if case .prose(let prose) = message.kind { return prose.text }
            return nil
        }
        case .reset:
            messages.removeAll()
            hasMore = false
            Task { await loadLatest() }
        case .sessionRemoved: session = session.withState(.ended)
        case .terminalBlocks, .unknown: break
        }
    }

    private func upsert(_ incoming: [ChatMessage]) {
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        for message in incoming { byID[message.id] = message }
        messages = byID.values.sorted { $0.seq < $1.seq }
    }
}

private struct AgentChatComposer: View {
    @Bindable var model: AgentChatConversationStore

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message your agent…", text: $model.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
                .accessibilityIdentifier("AgentChatComposer")
            Button { Task { await model.send() } } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 31))
            }
            .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSending)
            .accessibilityLabel("Send message")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

private struct AgentChatMessageCell: View {
    let message: ChatMessage
    let answer: (Int) -> Void

    var body: some View {
        switch message.kind {
        case .prose(let prose): AgentChatBubble(role: message.role, text: prose.text)
        case .thought(let thought):
            DisclosureGroup {
                Text(thought.text).font(.footnote).foregroundStyle(.secondary)
            } label: {
                Label("Thought", systemImage: "brain.head.profile")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        case .toolUse(let tool): AgentChatCard(icon: "wrench.and.screwdriver", title: tool.toolName, detail: tool.summary, content: tool.output)
        case .terminal(let terminal): AgentChatCard(icon: "terminal", title: terminal.command, detail: terminal.isRunning ? "Running" : "Finished", content: terminal.output, monospace: true)
        case .fileEdit(let edit): AgentChatCard(icon: "doc.badge.gearshape", title: edit.filePath, detail: edit.operation.rawValue.capitalized, content: edit.unifiedDiff, monospace: true)
        case .permissionRequest(let permission):
            VStack(alignment: .leading, spacing: 9) {
                Label(permission.title, systemImage: "lock.shield")
                    .font(.headline)
                Text(permission.subject).font(.callout).textSelection(.enabled)
                if permission.resolution == nil {
                    HStack {
                        Button("Allow") { answer(0) }.buttonStyle(.borderedProminent)
                        Button("Deny") { answer(1) }.buttonStyle(.bordered)
                    }
                } else {
                    Text(permission.resolution!.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        case .question(let question):
            VStack(alignment: .leading, spacing: 10) {
                Text(question.prompt).font(.headline)
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    Button { answer(index) } label: {
                        HStack {
                            Text(option.label)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(question.selectedOptionLabel != nil)
                }
            }
            .padding(14)
            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        case .status(let status):
            HStack {
                Rectangle().fill(.quaternary).frame(height: 1)
                Text(status.event.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(.quaternary).frame(height: 1)
            }
        case .attachment(let attachment):
            Label(attachment.displayName ?? "Attachment", systemImage: "paperclip")
                .font(.subheadline).foregroundStyle(.secondary)
        case .unsupported(let payload):
            AgentChatCard(icon: "questionmark", title: "Unsupported event", detail: payload.rawType, content: nil)
        }
    }
}

private struct AgentChatBubble: View {
    let role: ChatRole
    let text: String

    var body: some View {
        HStack {
            if role == .user { Spacer(minLength: 34) }
            Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
                .font(.body)
                .foregroundStyle(role == .user ? .white : .primary)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .background(role == .user ? Color.accentColor : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            if role != .user { Spacer(minLength: 34) }
        }
    }
}

private struct AgentChatCard: View {
    let icon: String
    let title: String
    let detail: String
    let content: String?
    var monospace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
            if let content, !content.isEmpty {
                Text(content)
                    .font(monospace ? .system(.footnote, design: .monospaced) : .footnote)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(13)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct AgentChatProviderMark: View {
    let provider: ChatAgentKind

    var body: some View {
        Text(String(provider.displayName.prefix(1)))
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 42, height: 42)
            .background(providerColor, in: Circle())
    }

    private var providerColor: Color {
        switch provider {
        case .claude: return .orange
        case .codex: return .green
        case .opencode: return .purple
        case .other: return .gray
        }
    }
}

private struct AgentChatStateLabel: View {
    let state: ChatAgentState

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
    }

    private var label: String {
        switch state {
        case .idle: return "Ready"
        case .working: return "Working"
        case .needsInput: return "Needs your input"
        case .ended: return "Ended"
        }
    }

    private var color: Color {
        switch state {
        case .idle: return .green
        case .working: return .blue
        case .needsInput: return .orange
        case .ended: return .gray
        }
    }
}

#endif
