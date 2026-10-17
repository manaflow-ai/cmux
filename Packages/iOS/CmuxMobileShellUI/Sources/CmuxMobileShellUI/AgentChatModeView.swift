import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import PhotosUI
import SwiftUI
import UIKit

/// A dedicated ChatGPT/Codex-style mode for coding-agent sessions.
///
/// The mode owns its own navigation shell so the agent history stays visible
/// while a user moves between sessions. ``NavigationSplitView`` gives iPad a
/// persistent history column and turns that column into a native push stack
/// on iPhone.
struct AgentChatModeView: View {
    @Bindable var store: CMUXMobileShellStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model = AgentChatModeModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var isShowingNewSessionComposer = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            AgentChatSidebar(
                model: model,
                searchText: $searchText,
                isLoading: isLoading,
                isConnected: store.connectionState == .connected
                    && model.connectionState == .connected,
                selectSession: selectSession,
                showNewSessionComposer: { isShowingNewSessionComposer = true },
                refresh: { await refresh() }
            )
            .navigationTitle("Agents")
            .navigationBarTitleDisplayMode(.inline)
        } detail: {
            AgentChatDetail(
                store: store,
                model: model,
                isLoading: isLoading,
                isConnected: store.connectionState == .connected
                    && model.connectionState == .connected,
                showSidebar: { columnVisibility = .all },
                refresh: { await refresh() }
            )
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await updateSourceAndRefresh()
        }
        .onDisappear {
            // The host and selected-session streams are long-lived. Tear them
            // down when the full-screen mode closes so the view's @State model
            // cannot retain itself through its observation task and keep a
            // stale mobile.chat subscription alive behind the workspace shell.
            model.updateSource(nil)
        }
        .onChange(of: store.connectionState) { _, _ in
            Task { await updateSourceAndRefresh() }
        }
        .onChange(of: model.sessions.count) { _, _ in
            // A successful empty result is still a loaded state. Keeping this
            // local avoids making the model expose transport bookkeeping just
            // for a progress indicator.
            isLoading = false
        }
        .alert("Agent mode error", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("OK", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        // Agent Chat owns the same task composer used by the workspace shell.
        // A task created here is sent through `workspace.create` with the
        // selected provider's launch command, so the resulting agent session
        // appears in this mode through the normal session event stream.
        .taskComposerPresentation(
            isPresented: $isShowingNewSessionComposer,
            onDismiss: {
                Task { await refresh() }
            }
        ) { launch, switchDraft in
            TaskComposerSheet(
                store: store,
                launchIntent: launch.intent,
                onSwitchDraft: switchDraft
            )
        }
        .accessibilityIdentifier("MobileAgentChatMode")
    }

    private func updateSourceAndRefresh() async {
        isLoading = true
        model.updateSource(store.makeChatEventSource())
        await model.refresh()
        isLoading = false
    }

    private func refresh() async {
        isLoading = true
        await model.refresh()
        isLoading = false
    }

    private func selectSession(_ session: ChatSessionDescriptor) {
        model.select(session)
        // Compact NavigationSplitView presents the detail column as a push;
        // regular width keeps both columns available for rapid triage.
        if horizontalSizeClass == .compact {
            columnVisibility = .detailOnly
        }
    }
}

private struct AgentChatSidebar: View {
    @Bindable var model: AgentChatModeModel
    @Binding var searchText: String
    let isLoading: Bool
    let isConnected: Bool
    let selectSession: (ChatSessionDescriptor) -> Void
    let showNewSessionComposer: () -> Void
    let refresh: () async -> Void

    private var filteredSessions: [ChatSessionDescriptor] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.visibleSessions }
        return model.visibleSessions.filter { session in
            [
                session.title,
                session.agentKind.displayName,
                session.workingDirectory,
                session.workspaceID,
                session.terminalID
            ]
            .compactMap { $0 }
            .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var needsAttention: [ChatSessionDescriptor] {
        filteredSessions.filter { $0.state.needsAttention }
    }

    private var recentSessions: [ChatSessionDescriptor] {
        filteredSessions.filter { !$0.state.needsAttention }
    }

    var body: some View {
        VStack(spacing: 0) {
            AgentSidebarHeader(
                selectedProvider: $model.selectedProvider,
                showNewSessionComposer: showNewSessionComposer,
                refresh: refresh
            )

            if !isConnected {
                AgentConnectionNotice(isConnected: false, refresh: refresh)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            } else if let error = model.errorMessage {
                AgentErrorNotice(message: error)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            List {
                if isLoading {
                    AgentSessionLoadingRows()
                        .listRowSeparator(.hidden)
                } else if filteredSessions.isEmpty {
                    AgentSessionEmptyRow(
                        hasSearch: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        isConnected: isConnected,
                        clearSearch: { searchText = "" },
                        showNewSessionComposer: showNewSessionComposer
                    )
                    .listRowSeparator(.hidden)
                } else {
                    if !needsAttention.isEmpty {
                        Section("Needs your attention") {
                            ForEach(needsAttention) { session in
                                AgentChatSessionRow(
                                    session: session,
                                    isSelected: session.id == model.selectedSessionID,
                                    select: { selectSession(session) }
                                )
                            }
                        }
                    }
                    Section("Recent") {
                        ForEach(recentSessions) { session in
                            AgentChatSessionRow(
                                session: session,
                                isSelected: session.id == model.selectedSessionID,
                                select: { selectSession(session) }
                            )
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search sessions")
            .refreshable { await refresh() }
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("MobileAgentSessionsSidebar")
    }
}

private struct AgentSidebarHeader: View {
    @Binding var selectedProvider: String
    let showNewSessionComposer: () -> Void
    let refresh: () async -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label("Agent history", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button { showNewSessionComposer() } label: {
                    Label("New session", systemImage: "plus")
                }
                Button { Task { await refresh() } } label: {
                    Label("Refresh sessions", systemImage: "arrow.clockwise")
                }
                Divider()
                Picker("Provider", selection: $selectedProvider) {
                    Text("All agents").tag("all")
                    Text("Claude Code").tag("claude")
                    Text("Codex").tag("codex")
                    Text("OpenCode").tag("opencode")
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel("New agent session and filters")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

private struct AgentChatDetail: View {
    let store: CMUXMobileShellStore
    @Bindable var model: AgentChatModeModel
    @Environment(\.dismiss) private var dismiss
    let isLoading: Bool
    let isConnected: Bool
    let showSidebar: () -> Void
    let refresh: () async -> Void

    var body: some View {
        Group {
            if isLoading {
                AgentLoadingState()
            } else if model.selectedSession == nil {
                AgentNoSelectionState(isConnected: isConnected, refresh: refresh)
            } else {
                VStack(spacing: 0) {
                    if !isConnected {
                        AgentConnectionNotice(isConnected: false, refresh: refresh)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    } else if let error = model.errorMessage {
                        AgentErrorNotice(message: error)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                    }
                    AgentChatTranscriptView(store: store, model: model)
                }
            }
        }
        .navigationTitle(model.selectedSession?.title ?? "Agents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: showSidebar) {
                    Image(systemName: "sidebar.left")
                }
                .accessibilityLabel("Agent sessions")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    Button { dismiss() } label: {
                        Label("Close", systemImage: "xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Agent mode options")
            }
        }
    }
}

private struct AgentLoadingState: View {
    var body: some View {
        ContentUnavailableView {
            ProgressView()
                .controlSize(.large)
        } description: {
            Text("Loading agent sessions…")
        }
        .accessibilityIdentifier("MobileAgentLoadingState")
    }
}

private struct AgentNoSelectionState: View {
    let isConnected: Bool
    let refresh: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label(
                isConnected ? "Choose an agent session" : "Reconnecting to your Mac",
                systemImage: isConnected ? "sparkles" : "wifi.exclamationmark"
            )
        } description: {
            Text(isConnected
                ? "Select a session from Agent history to view its conversation."
                : "Your agent history will appear here when the connection is restored.")
        } actions: {
            Button {
                Task { await refresh() }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
        .accessibilityIdentifier(isConnected ? "MobileAgentNoSelectionState" : "MobileAgentReconnectingState")
    }
}

private struct AgentSessionEmptyRow: View {
    let hasSearch: Bool
    let isConnected: Bool
    let clearSearch: () -> Void
    let showNewSessionComposer: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: hasSearch ? "magnifyingglass" : (isConnected ? "sparkles" : "wifi.exclamationmark"))
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(hasSearch ? "No matching sessions" : (isConnected ? "No agent sessions yet" : "Waiting for a connection"))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(hasSearch
                ? "Try a different name, project, or provider."
                : (isConnected
                    ? "Start Claude Code, Codex, or OpenCode in cmux to see it here."
                    : "Reconnect to your Mac to load agent history."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if hasSearch {
                Button("Clear search", action: clearSearch)
                    .buttonStyle(.bordered)
            } else if isConnected {
                Button("Start a new session", action: showNewSessionComposer)
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

private struct AgentSessionLoadingRows: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProgressView()
            Text("Loading sessions…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 32)
    }
}

private struct AgentConnectionNotice: View {
    let isConnected: Bool
    let refresh: () async -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isConnected ? "checkmark.circle.fill" : "wifi.exclamationmark")
                .foregroundStyle(isConnected ? .green : .orange)
            Text(isConnected ? "Connected to your Mac" : "Reconnecting to your Mac…")
                .font(.caption.weight(.medium))
            Spacer(minLength: 8)
            if !isConnected {
                Button("Retry") { Task { await refresh() } }
                    .font(.caption.weight(.semibold))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct AgentErrorNotice: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
}

private struct AgentChatSessionRow: View {
    let session: ChatSessionDescriptor
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title ?? session.agentKind.displayName)
                        .font(.headline)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(session.agentKind.displayName)
                        if let cwd = session.workingDirectory {
                            Text(cwd)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let activity = session.lastActivityAt {
                            Text(activity, style: .relative)
                                .lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                AgentStatusIndicator(state: session.state)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if isSelected { Capsule().fill(.tint).frame(width: 3) }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.agentKind.displayName), \(session.title ?? "Untitled session")")
    }

    private var iconName: String {
        switch session.agentKind.sourceName {
        case "claude": return "c.circle.fill"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        case "opencode": return "square.stack.3d.up.fill"
        default: return "sparkles"
        }
    }

    private var iconColor: Color {
        switch session.agentKind.sourceName {
        case "claude": return .orange
        case "codex": return .green
        case "opencode": return .purple
        default: return .accentColor
        }
    }
}

private struct AgentStatusIndicator: View {
    let state: ChatAgentState

    var body: some View {
        Group {
            switch state {
            case .working: ProgressView().controlSize(.small)
            case .needsInput: Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            case .failed: Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.red)
            case .idle: Circle().fill(.secondary).frame(width: 8, height: 8)
            case .ended: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .working: return "Working"
        case .needsInput: return "Needs input"
        case .failed: return "Turn failed; retry available"
        case .idle: return "Idle"
        case .ended: return "Ended"
        }
    }
}

private struct AgentChatTranscriptView: View {
    let store: CMUXMobileShellStore
    @Bindable var model: AgentChatModeModel
    @FocusState private var composerFocused: Bool
    @State private var suppressNextMessageAutoScroll = false

    var body: some View {
        VStack(spacing: 0) {
            if let session = model.selectedSession {
                AgentExecutionContextBar(session: session)
                if case .failed = session.state {
                    AgentFailedTurnNotice(
                        reason: model.selectedFailureReason,
                        isRetrying: model.retryingSessionIDs.contains(session.id),
                        canRetry: model.canRetrySelectedTurn,
                        retry: { Task { await model.retryLastTurn() } }
                    )
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.selectedHasMoreHistory {
                            Button {
                                let countBeforeLoad = model.selectedMessages.count
                                suppressNextMessageAutoScroll = true
                                Task {
                                    await model.loadOlderMessages()
                                    // If the page was empty or the request was
                                    // cancelled, no count change will arrive
                                    // to consume the suppression token.
                                    if model.selectedMessages.count == countBeforeLoad {
                                        suppressNextMessageAutoScroll = false
                                    }
                                }
                            } label: {
                                Label("Load earlier messages", systemImage: "chevron.up")
                                    .font(.footnote.weight(.medium))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .padding(.bottom, 2)
                        }
                        if model.selectedMessages.isEmpty,
                           model.selectedTerminalBlocks.isEmpty,
                           model.selectedStreamingMessage == nil {
                            ContentUnavailableView("Start a task", systemImage: "sparkles", description: Text("Ask your coding agent to inspect, change, or explain your project."))
                                .padding(.top, 80)
                        } else {
                            if model.selectedSession?.kind == .terminal {
                                ForEach(model.selectedTerminalBlocks) { block in
                                    AgentTerminalBlockView(block: block)
                                        .id("terminal-\(block.id)")
                                }
                            }
                            ForEach(model.selectedMessages) { message in
                                AgentChatMessageView(message: message, answer: { index, requestID in
                                    Task { await model.answer(optionIndex: index, requestID: requestID) }
                                })
                                .id(message.id)
                            }
                            if let streaming = model.selectedStreamingMessage {
                                AgentChatMessageView(message: streaming, isStreaming: true)
                                    .id("streaming")
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: model.selectedMessages.count) { _, _ in
                    guard !suppressNextMessageAutoScroll else {
                        suppressNextMessageAutoScroll = false
                        return
                    }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: model.selectedStreamingMessage?.id) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .refreshable { await model.refresh() }
            }
            AgentChatComposer(store: store, model: model, focused: $composerFocused)
        }
        .background(Color(.systemBackground))
        .accessibilityIdentifier("MobileAgentConversation")
    }
}

private struct AgentFailedTurnNotice: View {
    let reason: String?
    let isRetrying: Bool
    let canRetry: Bool
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Turn failed")
                    .font(.subheadline.weight(.semibold))
                if let reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else {
                    Text("The agent did not complete this turn.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button {
                retry()
            } label: {
                if isRetrying {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canRetry || isRetrying)
            .accessibilityLabel(isRetrying ? "Retrying failed turn" : "Retry failed turn")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileAgentFailedTurnNotice")
    }
}

private struct AgentExecutionContextBar: View {
    let session: ChatSessionDescriptor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(session.agentKind.displayName, systemImage: "sparkles")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                AgentStatusIndicator(state: session.state)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    AgentContextPill(
                        title: session.title ?? "Untitled task",
                        subtitle: "Project",
                        systemImage: "folder"
                    )
                    if let workspaceID = session.workspaceID {
                        AgentContextPill(
                            title: workspaceID,
                            subtitle: "Workspace",
                            systemImage: "square.grid.2x2"
                        )
                    }
                    if let terminalID = session.terminalID {
                        AgentContextPill(
                            title: terminalID,
                            subtitle: "Host",
                            systemImage: "desktopcomputer"
                        )
                    }
                    if let cwd = session.workingDirectory {
                        AgentContextPill(
                            title: cwd,
                            subtitle: "Worktree",
                            systemImage: "point.3.connected.trianglepath.dotted"
                        )
                    }
                }
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .accessibilityElement(children: .combine)
    }
}

private struct AgentContextPill: View {
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(subtitle.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct AgentChatMessageView: View {
    let message: ChatMessage
    var isStreaming = false
    var answer: ((Int, String) -> Void)?

    var body: some View {
        Group {
            switch message.kind {
            case .prose(let prose):
                AgentProseBubble(text: prose.text, role: message.role, isStreaming: isStreaming)
            case .thought(let thought):
                AgentThoughtCard(text: thought.text)
            case .toolUse(let tool):
                AgentToolCard(tool: tool)
            case .terminal(let terminal):
                AgentTerminalCard(terminal: terminal)
            case .fileEdit(let edit):
                AgentDiffCard(edit: edit)
            case .permissionRequest(let request):
                AgentPermissionCard(request: request, answer: { index in answer?(index, message.id) })
            case .question(let question):
                AgentQuestionCard(question: question, answer: { index in answer?(index, message.id) })
            case .status(let status):
                Text(status.detail ?? status.event.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            case .attachment(let attachment):
                Label(attachment.displayName ?? "Attachment", systemImage: attachment.media == .image ? "photo" : "doc")
                    .font(.subheadline)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            case .unsupported(let payload):
                Label("Unsupported agent event: \(payload.rawType)", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .agentMessageActions(copying: copyText)
    }

    /// ChatGPT's long-press message menu is useful for agent output too: it
    /// lets a user move a response, command, or diff into another app without
    /// first selecting a small range of text. Keep the source text assembled
    /// here so every event card gets the same copy/share affordance.
    private var copyText: String? {
        switch message.kind {
        case .prose(let prose):
            return prose.text
        case .thought(let thought):
            return thought.text
        case .toolUse(let tool):
            var lines = [tool.summary]
            if let input = tool.inputDetail, !input.isEmpty { lines.append("Input:\n\(input)") }
            if let paths = tool.referencedPaths, !paths.isEmpty { lines.append(paths.joined(separator: "\n")) }
            if let output = tool.output, !output.isEmpty { lines.append("Output:\n\(output)") }
            return lines.joined(separator: "\n")
        case .terminal(let terminal):
            var lines = [terminal.command]
            if let output = terminal.output, !output.isEmpty { lines.append(output) }
            if let exitCode = terminal.exitCode { lines.append("Exit \(exitCode)") }
            return lines.joined(separator: "\n")
        case .fileEdit(let edit):
            return edit.unifiedDiff ?? edit.filePath
        case .permissionRequest(let request):
            return [request.title, request.subject].joined(separator: "\n")
        case .question(let question):
            let options = question.options.map { "• \($0.label)" }.joined(separator: "\n")
            return options.isEmpty ? question.prompt : "\(question.prompt)\n\(options)"
        case .status(let status):
            return status.detail ?? status.event.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        case .attachment(let attachment):
            return attachment.displayName
        case .unsupported(let payload):
            return payload.rawType
        }
    }
}

private struct AgentMessageActions: ViewModifier {
    let copyText: String?

    func body(content: Content) -> some View {
        guard let copyText, !copyText.isEmpty else { return AnyView(content) }
        return AnyView(
            content
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = copyText
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    ShareLink(item: copyText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
                .accessibilityAction(named: Text("Copy")) {
                    UIPasteboard.general.string = copyText
                }
        )
    }
}

private extension View {
    func agentMessageActions(copying text: String?) -> some View {
        modifier(AgentMessageActions(copyText: text))
    }
}

private struct AgentProseBubble: View {
    let text: String
    let role: ChatRole
    let isStreaming: Bool

    var body: some View {
        HStack {
            if role == .user { Spacer(minLength: 36) }
            AgentChatMarkdownText(markdown: text, color: role == .user ? .white : .primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(role == .user ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                .foregroundStyle(role == .user ? .white : .primary)
                .opacity(isStreaming ? 0.9 : 1)
            if role != .user { Spacer(minLength: 36) }
        }
    }
}

/// Lightweight Markdown rendering owned by Agent mode. Keeping this local
/// keeps transcript presentation decisions self-contained.
private struct AgentChatMarkdownText: View {
    let markdown: String
    let color: Color

    var body: some View {
        Text(renderedMarkdown)
        .font(.body)
        .foregroundStyle(color)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var renderedMarkdown: AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.failurePolicy = .returnPartiallyParsedIfPossible
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

private struct AgentTerminalBlockView: View {
    let block: TerminalCommandBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: block.isInteractive ? "rectangle.inset.filled" : "terminal")
                Text(block.command.isEmpty ? "Shell" : block.command)
                    .font(.caption.monospaced().weight(.semibold))
                    .lineLimit(2)
                Spacer()
                if block.isRunning {
                    ProgressView().controlSize(.mini)
                } else if let exitCode = block.exitCode {
                    Text("Exit \(exitCode)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(block.failed ? .red : .green)
                }
            }
            if !block.output.isEmpty {
                Text(block.output)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .agentMessageActions(copying: copyText)
    }

    private var copyText: String {
        var lines = [block.command]
        if !block.output.isEmpty { lines.append(block.output) }
        if let exitCode = block.exitCode { lines.append("Exit \(exitCode)") }
        return lines.joined(separator: "\n")
    }
}

private struct AgentThoughtCard: View {
    let text: String
    var body: some View {
        DisclosureGroup("Thinking") { Text(text).font(.caption).foregroundStyle(.secondary) }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AgentToolCard: View {
    let tool: ChatToolUse
    @State private var isInputExpanded = false
    @State private var isOutputExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(tool.summary, systemImage: tool.status == .running ? "arrow.triangle.2.circlepath" : "wrench.and.screwdriver")
                .font(.subheadline.weight(.semibold))
            if let inputDetail = tool.inputDetail,
               !inputDetail.isEmpty {
                DisclosureGroup("Input", isExpanded: $isInputExpanded) {
                    Text(inputDetail)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .font(.caption.weight(.medium))
            }
            if let paths = tool.referencedPaths, !paths.isEmpty {
                Label(paths.joined(separator: ", "), systemImage: "folder")
                    .font(.caption2.monospaced())
                    .lineLimit(isInputExpanded ? nil : 2)
                    .textSelection(.enabled)
            }
            if let output = tool.output {
                DisclosureGroup("Output", isExpanded: $isOutputExpanded) {
                    Text(output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .font(.caption.weight(.medium))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AgentTerminalCard: View {
    let terminal: ChatTerminalCapture
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(terminal.command, systemImage: "terminal")
                .font(.caption.monospaced().weight(.semibold))
            if let output = terminal.output { Text(output).font(.caption.monospaced()).textSelection(.enabled) }
            if let exitCode = terminal.exitCode { Text("Exit \(exitCode)").font(.caption2).foregroundStyle(exitCode == 0 ? .green : .red) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
    }
}

private struct AgentDiffCard: View {
    let edit: ChatFileEdit
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(edit.filePath, systemImage: "doc.text")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let additions = edit.additions { Text("+\(additions)").foregroundStyle(.green) }
                if let deletions = edit.deletions { Text("-\(deletions)").foregroundStyle(.red) }
            }
            if let diff = edit.unifiedDiff {
                DisclosureGroup("View diff", isExpanded: $isExpanded) {
                    Text(diff)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(isExpanded ? nil : 12)
                }
                .font(.caption.weight(.medium))
            }
        }
        .font(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct AgentPermissionCard: View {
    let request: ChatPermissionRequest
    let answer: ((Int) -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: "hand.raised.fill")
                .font(.headline)
            Text(request.subject).font(.caption.monospaced()).textSelection(.enabled)
            if let scope = request.scope, !scope.isEmpty {
                Label("Scope: \(scope)", systemImage: "scope")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let resolution = request.resolution {
                Text(resolutionLabel(resolution)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(request.options.enumerated()), id: \.offset) { index, option in
                        permissionButton(index: index, option: option)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    private func resolutionLabel(_ resolution: ChatPermissionRequest.Resolution) -> String {
        switch resolution {
        case .approved: return "Allowed once"
        case .approvedAlways: return "Always allowed"
        case .approvedAll: return "All matching actions allowed"
        case .denied: return "Denied"
        case .expired: return "Expired"
        }
    }

    @ViewBuilder
    private func permissionButton(index: Int, option: ChatPermissionRequest.Option) -> some View {
        if index == request.options.count - 1 {
            Button(action: { answer?(index) }) {
                permissionButtonLabel(option)
            }
            .buttonStyle(.bordered)
        } else {
            Button(action: { answer?(index) }) {
                permissionButtonLabel(option)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func permissionButtonLabel(_ option: ChatPermissionRequest.Option) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(option.label).font(.subheadline.weight(.semibold))
            if let detail = option.detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AgentQuestionCard: View {
    let question: ChatQuestion
    let answer: ((Int) -> Void)?

    private var isPlanReview: Bool {
        let labels = question.options.map { $0.label.lowercased() }
        return labels.contains(where: { $0.contains("approve plan") })
            && labels.contains(where: { $0.contains("reject plan") })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isPlanReview {
                Label("Plan ready for review", systemImage: "checklist")
                    .font(.headline)
            }
            Text(question.prompt).font(isPlanReview ? .body : .headline)
            if let selected = question.selectedOptionLabel {
                Label("Answered: \(selected)", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionButton(index: index, option: option)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private func optionButton(index: Int, option: ChatQuestion.Option) -> some View {
        let button = Button {
            answer?(index)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(option.label).font(.subheadline.weight(.semibold))
                if let detail = option.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if index == 0 && isPlanReview {
            button
                .buttonStyle(.borderedProminent)
                .disabled(question.selectedOptionLabel != nil)
        } else {
            button
                .buttonStyle(.bordered)
                .disabled(question.selectedOptionLabel != nil)
        }
    }
}

private struct AgentChatComposer: View {
    let store: CMUXMobileShellStore
    @Bindable var model: AgentChatModeModel
    var focused: FocusState<Bool>.Binding
    @Environment(\.scenePhase) private var scenePhase
    @State private var isPhotoPickerPresented = false
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var dictation: ComposerDictationController

    init(
        store: CMUXMobileShellStore,
        model: AgentChatModeModel,
        focused: FocusState<Bool>.Binding
    ) {
        self.store = store
        self._model = Bindable(model)
        self.focused = focused
        self._dictation = State(initialValue: ComposerDictationController { event in
            event.recordAppDiagnostic(
                correlationID: model.selectedSessionID ?? "agent-chat",
                store: store
            )
        })
    }

    private var isSessionEnded: Bool {
        model.selectedSession?.state == .ended
    }

    var body: some View {
        VStack(spacing: 6) {
            if model.queuedSendCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("\(model.queuedSendCount) message queued")
                    Spacer()
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .accessibilityElement(children: .combine)
            }
            if !model.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.attachments) { attachment in
                            AgentChatAttachmentChip(attachment: attachment) {
                                model.removeAttachment(id: attachment.id)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Menu {
                    Button {
                        isPhotoPickerPresented = true
                    } label: {
                        Label("Photo Library", systemImage: "photo.on.rectangle")
                    }
                    Button {
                        Task { await model.stagePastedImages() }
                    } label: {
                        Label("Paste Image", systemImage: "doc.on.clipboard")
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel("Add attachment")
                .disabled(isSessionEnded || model.attachments.count >= 10)
                Button {
                    toggleDictation()
                } label: {
                    Image(systemName: dictation.state.isListening ? "mic.fill" : "mic")
                }
                .foregroundStyle(dictation.state.isListening ? .red : .secondary)
                .symbolEffect(.pulse, isActive: dictation.state.isListening)
                .disabled(isSessionEnded || !dictation.isAvailable)
                .accessibilityLabel(
                    dictation.state.isListening ? "Stop dictation" : "Start dictation"
                )
                .accessibilityIdentifier("MobileAgentComposerMic")
                TextField(
                    isSessionEnded ? "Session ended" : "Message your agent",
                    text: $model.draft,
                    axis: .vertical
                )
                    .lineLimit(1...6)
                    .focused(focused)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 10)
                    .disabled(isSessionEnded)
                    .disabled(dictation.locksComposerField)
                    .onChange(of: focused.wrappedValue) { _, isFocused in
                        guard !isFocused, !dictation.locksComposerField else { return }
                        dictation.stop()
                    }
                if model.selectedSession?.isWorking == true {
                    Button { Task { await model.interrupt() } } label: {
                        Image(systemName: "stop.circle.fill")
                    }
                    .foregroundStyle(.red)
                    .accessibilityLabel("Stop agent")
                    .disabled(isSessionEnded)
                }
                if model.selectedSession?.isWorking == true {
                    Menu {
                        Button {
                            dictation.cancel()
                            Task { await model.sendDraft() }
                        } label: {
                            Label("Queue for next turn", systemImage: "clock.arrow.circlepath")
                        }
                        Button {
                            dictation.cancel()
                            Task { await model.steerDraft() }
                        } label: {
                            Label("Steer current turn", systemImage: "arrow.uturn.forward")
                        }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                    .disabled(!canSend)
                    .accessibilityLabel("Send instruction")
                    .accessibilityHint("Choose whether to queue the instruction or steer the current turn")
                } else {
                    Button {
                        dictation.cancel()
                        Task { await model.sendDraft() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileAgentComposer")
        .accessibilityHint(isSessionEnded ? "This agent session has ended and is read only." : "")
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $photoSelection,
            maxSelectionCount: max(1, 10 - model.attachments.count),
            matching: .images
        )
        .onChange(of: photoSelection) { items in
            guard !items.isEmpty else { return }
            Task {
                await stagePhotos(items)
                photoSelection = []
            }
        }
        .onChange(of: model.selectedSessionID) { _, _ in
            // Session selection resets the draft and transcript source. Stop
            // any in-flight recognizer before those state changes can route a
            // late partial into the newly selected session.
            dictation.cancel()
        }
        .onChange(of: isSessionEnded) { _, ended in
            if ended {
                dictation.cancel()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                // Speech recognition must not keep the microphone open while
                // the app is backgrounded or inactive.
                dictation.cancel()
                return
            }
        }
        .onDisappear {
            dictation.cancel()
        }
    }

    private var canSend: Bool {
        !isSessionEnded
            && (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.attachments.isEmpty)
    }

    private func stagePhotos(_ items: [PhotosPickerItem]) async {
        let remaining = max(0, 10 - model.attachments.count)
        guard remaining > 0 else { return }
        for item in items.prefix(remaining) {
            guard !Task.isCancelled else { return }
            do {
                guard let imported = try await ImportedPhotoLibraryFile.load(item) else { continue }
                defer { try? FileManager.default.removeItem(at: imported.url) }
                guard imported.kind == .image,
                      let prepared = await MobileImageAttachmentPreparer().prepare(url: imported.url) else {
                    continue
                }
                let format: ChatOutboundAttachment.Format =
                    ["jpg", "jpeg"].contains(prepared.format.lowercased()) ? .jpeg : .png
                let stem = (imported.originalFileName as NSString).deletingPathExtension
                model.addAttachment(.init(
                    displayName: (stem.isEmpty ? "image" : stem) + (format == .jpeg ? ".jpeg" : ".png"),
                    data: prepared.data,
                    format: format,
                    thumbnailData: prepared.thumbnailData
                ))
            } catch is CancellationError {
                return
            } catch { continue }
        }
    }

    private func toggleDictation() {
        dictation.toggle(existingText: model.draft) { merged in
            model.draft = merged
        }
    }
}

private struct AgentChatAttachmentChip: View {
    let attachment: AgentChatModeModel.PendingAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let image = UIImage(data: attachment.thumbnailData ?? attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "photo")
                    .frame(width: 42, height: 42)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            Text(attachment.displayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.displayName)")
        }
        .padding(4)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private extension ChatSessionDescriptor {
    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }
}
