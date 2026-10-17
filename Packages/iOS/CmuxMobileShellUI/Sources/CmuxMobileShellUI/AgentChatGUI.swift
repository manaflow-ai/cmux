import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileSupport
import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

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
        .background(Color(uiColor: .systemBackground))
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
    private var streamTask: Task<Void, Never>?
    private var isRefreshing = false
    private var pendingFrames: [ChatSessionEventFrame] = []

    init(source: MobileChatEventSource) {
        self.source = source
    }

    var visibleSessions: [ChatSessionDescriptor] {
        let agents = sessions.filter { session in
            guard session.kind == .agent else { return false }
            switch session.agentKind {
            case .claude, .codex, .opencode: return true
            case .other: return false
            }
        }
        let filtered = selectedProvider.map { provider in
            agents.filter { $0.agentKind == provider }
        } ?? agents
        return ChatSessionDescriptor.openable(filtered)
    }

    func refresh() async {
        isLoading = sessions.isEmpty
        isRefreshing = true
        do {
            sessions = try await source.sessions(workspaceID: nil)
            errorMessage = nil
        } catch {
            errorMessage = "Couldn’t load agent sessions."
        }
        isRefreshing = false
        let frames = pendingFrames
        pendingFrames.removeAll()
        frames.forEach(apply)
        isLoading = false
    }

    func start() async {
        streamTask?.cancel()
        let stream = await source.sessionEvents()
        streamTask = Task { @MainActor [weak self] in
            for await frame in stream {
                guard !Task.isCancelled else { return }
                self?.apply(frame)
            }
        }
        await refresh()
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        pendingFrames.removeAll()
    }

    private func apply(_ frame: ChatSessionEventFrame) {
        guard !isRefreshing else {
            pendingFrames.append(frame)
            return
        }
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
    @State private var searchText = ""

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
                    List {
                        ForEach(groupedSessions) { group in
                            Section(group.title) {
                                ForEach(group.sessions) { session in
                                    Button {
                                        selectedSession = session
                                    } label: {
                                        AgentChatSessionRow(session: session)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("AgentChatSession-\(session.id)")
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Chats")
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
            .searchable(text: $searchText, prompt: "Search conversations")
            .refreshable { await model.refresh() }
            .task {
                await model.start()
            }
            .onDisappear { model.stop() }
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

    private var filteredSessions: [ChatSessionDescriptor] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return model.visibleSessions
        }
        let query = searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return model.visibleSessions.filter { session in
            [session.title, session.workingDirectory, session.agentKind.displayName]
                .compactMap { $0 }
                .contains { value in
                    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                        .contains(query)
                }
        }
    }

    private var groupedSessions: [AgentChatSessionGroup] {
        let calendar = Calendar.current
        var grouped: [Date: [ChatSessionDescriptor]] = [:]
        for session in filteredSessions {
            let date = calendar.startOfDay(for: session.lastActivityAt ?? .distantPast)
            grouped[date, default: []].append(session)
        }
        let today = calendar.startOfDay(for: Date())
        return grouped.keys.sorted(by: >).map { date in
            let title: String
            if date == today {
                title = "Today"
            } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), date == yesterday {
                title = "Yesterday"
            } else {
                title = date.formatted(date: .abbreviated, time: .omitted)
            }
            return AgentChatSessionGroup(title: title, sessions: grouped[date] ?? [])
        }
    }

    private struct AgentChatSessionGroup: Identifiable {
        let title: String
        let sessions: [ChatSessionDescriptor]

        var id: String { title }
    }
}

private struct AgentChatSessionRow: View {
    let session: ChatSessionDescriptor

    var body: some View {
        HStack(spacing: 14) {
            AgentChatProviderMark(provider: session.agentKind, size: 42)
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
                    Text(session.workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "cmux terminal")
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

private struct AgentChatEmptyConversation: View {
    let session: ChatSessionDescriptor

    var body: some View {
        VStack(spacing: 12) {
            AgentChatProviderMark(provider: session.agentKind, size: 56)
            Text(session.title?.isEmpty == false ? session.title! : "New conversation")
                .font(.title3.weight(.semibold))
            Text("Send a message to continue this \(session.agentKind.displayName) session.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 72)
        .accessibilityElement(children: .combine)
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
                        if model.messages.isEmpty && model.streamingProse == nil {
                            AgentChatEmptyConversation(session: model.session)
                        }
                        if model.hasMore {
                            Button("Load earlier messages") {
                                Task { await model.loadEarlier() }
                            }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                        }
                        ForEach(model.messages) { message in
                            AgentChatMessageCell(
                                message: message,
                                selectedOptionIndex: model.selectedQuestionOptionIndex(for: message),
                                answer: { index in
                                Task { await model.answer(message: message, optionIndex: index) }
                                }
                            )
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
            ToolbarItem(placement: .topBarLeading) {
                AgentChatProviderMark(provider: model.session.agentKind, size: 26)
                    .accessibilityLabel(model.session.agentKind.displayName)
            }
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
        .alert("Conversation", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
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
    var pendingAttachments: [AgentChatPendingAttachment] = []
    var isSending = false
    var errorMessage: String?
    private var streamTask: Task<Void, Never>?
    /// Events received while the initial history page is loading are held
    /// until that page is installed. Starting the live stream first closes
    /// the history/subscribe race without allowing a streamed update to be
    /// overwritten by the in-flight history response.
    private var isLoadingInitialHistory = false
    private var pendingEvents: [ChatSessionEvent] = []
    private var streamGeneration = UUID()
    /// Feed resolves all questions belonging to one request in a single RPC.
    /// Keep local choices until every card in that request has a selection.
    private var pendingQuestionSelections: [String: [String: String]] = [:]
    private var questionRepliesInFlight: Set<String> = []

    init(source: MobileChatEventSource, session: ChatSessionDescriptor) {
        self.source = source
        self.session = session
    }

    func start() async {
        stop()
        let generation = UUID()
        streamGeneration = generation
        isLoadingInitialHistory = true
        pendingEvents.removeAll()
        pendingQuestionSelections.removeAll()
        questionRepliesInFlight.removeAll()
        // Create the stream (and its local topic listener) before asking for
        // history. The stream's buffer holds frames while the history RPC is
        // in flight, so no tail update can land in the gap between the two.
        let eventStream = await source.events(sessionID: session.id)
        guard streamGeneration == generation else { return }
        streamTask = Task { [weak self] in
            for await event in eventStream {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.receive(event, generation: generation) }
            }
        }
        await loadLatest()
        guard streamGeneration == generation else { return }
        isLoadingInitialHistory = false
        let events = pendingEvents
        pendingEvents.removeAll()
        events.forEach(apply)
    }

    func stop() {
        streamGeneration = UUID()
        streamTask?.cancel()
        streamTask = nil
        isLoadingInitialHistory = false
        pendingEvents.removeAll()
        pendingQuestionSelections.removeAll()
        questionRepliesInFlight.removeAll()
    }

    func loadLatest() async {
        do {
            let page = try await source.history(sessionID: session.id, beforeSeq: nil, limit: 100)
            messages = page.messages
            hasMore = page.hasMore
            errorMessage = nil
        } catch is CancellationError {
            return
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
        guard (!text.isEmpty || !pendingAttachments.isEmpty), !isSending else { return }
        isSending = true
        do {
            try await source.send(
                text: text,
                attachments: pendingAttachments.map { $0.outbound },
                sessionID: session.id
            )
            draft = ""
            pendingAttachments.removeAll()
            session = session.withState(session.state.afterExplicitInput(at: Date()))
        } catch { errorMessage = "Your message wasn’t sent." }
        isSending = false
    }

    func interrupt() async {
        try? await source.interrupt(sessionID: session.id, hard: false)
    }

    func answer(message: ChatMessage, optionIndex: Int) async {
        switch message.kind {
        case .permissionRequest(let permission) where permission.resolution == nil:
            if let requestID = permission.requestID {
                try? await source.replyPermission(
                    requestID: requestID,
                    mode: optionIndex == 0 ? "once" : "deny"
                )
            } else {
                try? await source.answer(optionIndex: optionIndex, sessionID: session.id)
            }
        case .question(let question) where question.selectedOptionLabel == nil:
            if let requestID = question.requestID,
               question.options.indices.contains(optionIndex) {
                if question.questionID == "__cmux_exit_plan__" {
                    try? await source.replyExitPlan(
                        requestID: requestID,
                        mode: optionIndex == 0 ? "autoAccept" : "manual"
                    )
                } else {
                    await answerQuestion(
                        message: message,
                        question: question,
                        optionIndex: optionIndex,
                        requestID: requestID
                    )
                }
            } else {
                try? await source.answer(optionIndex: optionIndex, sessionID: session.id)
            }
        default:
            try? await source.answer(optionIndex: optionIndex, sessionID: session.id)
        }
    }

    /// Records one card's choice and submits the complete request only after
    /// every question in that request has a choice. The Feed wire method takes
    /// one ordered selections array, so sending a partial array would resolve
    /// a multi-question prompt with the wrong answers.
    private func answerQuestion(
        message: ChatMessage,
        question: ChatQuestion,
        optionIndex: Int,
        requestID: String
    ) async {
        guard question.options.indices.contains(optionIndex) else { return }

        let questions = messages.compactMap { candidate -> (ChatMessage, ChatQuestion)? in
            guard case .question(let candidateQuestion) = candidate.kind,
                  candidateQuestion.requestID == requestID else { return nil }
            return (candidate, candidateQuestion)
        }
        guard !questions.isEmpty else { return }

        var selections = pendingQuestionSelections[requestID] ?? [:]
        for (candidateMessage, candidateQuestion) in questions {
            // A resolved card can be restored from history before the rest of
            // its request arrives. Preserve its answer when the option id is
            // still available; unresolved cards are filled from local taps.
            if let selectedLabel = candidateQuestion.selectedOptionLabel,
               let selectedOption = candidateQuestion.options.first(where: { $0.label == selectedLabel }) {
                selections[questionSelectionKey(message: candidateMessage, question: candidateQuestion)] = selectedOption.id
            }
        }
        selections[questionSelectionKey(message: message, question: question)] = question.options[optionIndex].id
        pendingQuestionSelections[requestID] = selections

        let unresolved = questions.filter { $0.1.selectedOptionLabel == nil }
        guard unresolved.allSatisfy({ selections[questionSelectionKey(message: $0.0, question: $0.1)] != nil }) else {
            return
        }
        guard !questionRepliesInFlight.contains(requestID) else { return }

        let orderedSelections = questions.compactMap { pair -> String? in
            let (candidateMessage, candidateQuestion) = pair
            guard let selectedID = selections[questionSelectionKey(message: candidateMessage, question: candidateQuestion)] else {
                return nil
            }
            // Feed's reply contract carries the human-readable answer string;
            // option ids remain local UI identities and may be provider-only.
            return candidateQuestion.options.first(where: { $0.id == selectedID })?.label
        }
        guard orderedSelections.count == questions.count else { return }

        questionRepliesInFlight.insert(requestID)
        do {
            try await source.replyQuestion(requestID: requestID, selections: orderedSelections)
            pendingQuestionSelections.removeValue(forKey: requestID)
        } catch is CancellationError {
            pendingQuestionSelections.removeValue(forKey: requestID)
        } catch {
            errorMessage = "Your answer wasn’t sent."
            pendingQuestionSelections.removeValue(forKey: requestID)
        }
        questionRepliesInFlight.remove(requestID)
    }

    func selectedQuestionOptionIndex(for message: ChatMessage) -> Int? {
        guard case .question(let question) = message.kind,
              question.selectedOptionLabel == nil,
              let requestID = question.requestID,
              let selectedID = pendingQuestionSelections[requestID]?[questionSelectionKey(message: message, question: question)] else {
            return nil
        }
        return question.options.firstIndex { $0.id == selectedID }
    }

    private func questionSelectionKey(message: ChatMessage, question: ChatQuestion) -> String {
        question.questionID ?? message.id
    }

    private func receive(_ event: ChatSessionEvent, generation: UUID) {
        guard streamGeneration == generation else { return }
        apply(event)
    }

    private func apply(_ event: ChatSessionEvent) {
        guard !isLoadingInitialHistory else {
            pendingEvents.append(event)
            return
        }
        reduce(event)
    }

    private func reduce(_ event: ChatSessionEvent) {
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
            pendingQuestionSelections.removeAll()
            questionRepliesInFlight.removeAll()
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

private struct AgentChatPendingAttachment: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let format: ChatOutboundAttachment.Format

    var outbound: ChatOutboundAttachment {
        ChatOutboundAttachment(data: data, format: format)
    }
}

private extension Data {
    var looksLikeJPEG: Bool {
        count >= 3 && self[startIndex] == 0xFF && self[index(startIndex, offsetBy: 1)] == 0xD8
    }
}

private struct AgentChatComposer: View {
    @Bindable var model: AgentChatConversationStore
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var isLoadingAttachment = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.pendingAttachments) { attachment in
                            HStack(spacing: 6) {
                                Image(systemName: "photo.fill")
                                Text("Image")
                                    .font(.caption.weight(.medium))
                                Button {
                                    model.pendingAttachments.removeAll { $0.id == attachment.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 7)
                            .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $pickerSelection, maxSelectionCount: 4, matching: .images) {
                    Image(systemName: "plus")
                        .font(.headline.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
                }
                .accessibilityLabel("Attach image")
                .disabled(isLoadingAttachment || model.isSending)
                TextField("Message your agent", text: $model.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityIdentifier("AgentChatComposer")
                    .onSubmit { Task { await model.send() } }
                Button { Task { await model.send() } } label: {
                    Image(systemName: "arrow.up")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(canSend ? Color.accentColor : Color.gray, in: Circle())
                }
                .disabled(!canSend || model.isSending)
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: pickerSelection) { _, items in
            guard !items.isEmpty else { return }
            isLoadingAttachment = true
            Task {
                await load(items)
                await MainActor.run {
                    pickerSelection = []
                    isLoadingAttachment = false
                }
            }
        }
    }

    private var canSend: Bool {
        !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.pendingAttachments.isEmpty
    }

    private func load(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else { continue }
            let format: ChatOutboundAttachment.Format = data.looksLikeJPEG ? .jpeg : .png
            await MainActor.run {
                model.pendingAttachments.append(AgentChatPendingAttachment(data: data, format: format))
            }
        }
    }
}

private struct AgentChatMessageCell: View {
    let message: ChatMessage
    let selectedOptionIndex: Int?
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
                            Image(systemName: selectedOptionIndex == index ? "checkmark.circle.fill" : "chevron.right")
                                .font(.caption)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(selectedOptionIndex == index ? .accentColor : nil)
                    .disabled(question.selectedOptionLabel != nil || selectedOptionIndex != nil)
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
    let size: CGFloat

    var body: some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(providerColor, in: Circle())
    }

    private var symbolName: String {
        switch provider {
        case .claude: return "sparkles"
        case .codex: return "command"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .other: return "bubble.left"
        }
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
