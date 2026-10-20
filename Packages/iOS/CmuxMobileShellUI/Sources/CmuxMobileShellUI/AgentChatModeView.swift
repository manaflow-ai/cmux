import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A dedicated ChatGPT/Codex-style mode for coding-agent sessions.
///
/// The mode owns its own navigation shell so the agent history stays visible
/// while a user moves between sessions. iPad keeps a persistent history column;
/// compact iPhone uses an explicit push stack so a session selection remains
/// deterministic across SwiftUI layout changes.
struct AgentChatModeView: View {
    @Bindable var store: CMUXMobileShellStore
    private let injectedSource: (any AgentChatSessionSource)?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var model = AgentChatModeModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    /// Compact iPhone navigation is an explicit path. ``NavigationSplitView``
    /// can keep its sidebar column mounted after a button selection, so merely
    /// changing its visibility does not reliably push the detail column.
    @State private var compactNavigationPath: [String] = []
    @State private var searchText = ""
    @State private var isLoading = true
    @State private var isShowingNewSessionComposer = false
    @Environment(\.scenePhase) private var scenePhase

    init(
        store: CMUXMobileShellStore,
        source: (any AgentChatSessionSource)? = nil
    ) {
        self._store = Bindable(store)
        self.injectedSource = source
        _model = State(initialValue: AgentChatModeModel(source: source))
    }

    private var isConnected: Bool {
        if injectedSource != nil { return model.connectionState == .connected }
        return store.connectionState == .connected && model.connectionState == .connected
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                // Use the same explicit path model as the workspace shell's
                // compact navigation. A button-driven selection updates the
                // path, which makes the push deterministic on iPhone.
                NavigationStack(path: $compactNavigationPath) {
                    sidebarView
                        .navigationDestination(for: String.self) { _ in
                            detailView
                        }
                }
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebarView
                } detail: {
                    detailView
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .task {
            await updateSourceAndRefresh()
        }
        .onChange(of: searchText, initial: true) { _, value in
            model.sessionSearchQuery = value
            model.beginTranscriptSearch()
            model.reconcileSelectionToFilter()
        }
        .onChange(of: model.selectedProvider) { _, _ in
            model.reconcileSelectionToFilter()
        }
        .onChange(of: scenePhase) { _, phase in
            // A suspended iOS process can miss the host's best-effort event
            // burst. Reconcile the authoritative list and selected transcript
            // as soon as the mode returns to the foreground.
            guard phase == .active else { return }
            Task { await refresh() }
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
        .onChange(of: model.selectedSessionID) { _, sessionID in
            guard horizontalSizeClass == .compact else { return }
            if let sessionID {
                // Host reconciliation can replace or remove the selected
                // session while a detail route is visible. Keep the route
                // bound to the authoritative selection instead of showing a
                // stale transcript under a different session title.
                guard !compactNavigationPath.isEmpty else { return }
                if compactNavigationPath.last != sessionID {
                    compactNavigationPath = [sessionID]
                }
            } else if !compactNavigationPath.isEmpty {
                compactNavigationPath.removeAll()
            }
        }
        .alert(AgentChatStrings.modeError, isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button(AgentChatStrings.ok, role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? AgentChatStrings.unknownError)
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
        model.updateSource(injectedSource ?? store.makeChatEventSource())
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
        // Compact navigation is an explicit push stack. Regular width keeps
        // both split columns available for rapid triage.
        if horizontalSizeClass == .compact {
            compactNavigationPath = [session.id]
        } else {
            columnVisibility = .detailOnly
        }
    }

    private var sidebarView: some View {
        AgentChatSidebar(
            model: model,
            searchText: $searchText,
            isLoading: isLoading,
            isConnected: isConnected,
            selectSession: selectSession,
            showNewSessionComposer: { isShowingNewSessionComposer = true },
            refresh: { await refresh() }
        )
        .navigationTitle(AgentChatStrings.agents)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel(AgentChatStrings.close)
                .accessibilityIdentifier("MobileAgentCloseMode")
            }
        }
    }

    private var detailView: some View {
        AgentChatDetail(
            store: store,
            model: model,
            isLoading: isLoading,
            isConnected: isConnected,
            showSidebar: showSidebar,
            closeMode: { dismiss() },
            refresh: { await refresh() }
        )
    }

    private func showSidebar() {
        if horizontalSizeClass == .compact {
            compactNavigationPath.removeAll()
        } else {
            columnVisibility = .all
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
        model.visibleSessions
    }

    private var pinned: [ChatSessionDescriptor] {
        model.pinnedSessions
    }

    private var needsAttention: [ChatSessionDescriptor] {
        filteredSessions.filter { !model.pinnedSessionIDs.contains($0.id) && $0.state.needsAttention }
    }

    private var recentSessions: [ChatSessionDescriptor] {
        filteredSessions.filter { !model.pinnedSessionIDs.contains($0.id) && !$0.state.needsAttention }
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
                } else if filteredSessions.isEmpty && model.visibleArchivedSessions.isEmpty {
                    AgentSessionEmptyRow(
                        hasSearch: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        isConnected: isConnected,
                        clearSearch: { searchText = "" },
                        showNewSessionComposer: showNewSessionComposer
                    )
                    .listRowSeparator(.hidden)
                } else {
                    if !pinned.isEmpty {
                        Section(AgentChatStrings.pinned) {
                            ForEach(pinned) { session in
                                AgentChatSessionRow(
                                    session: session,
                                    isSelected: session.id == model.selectedSessionID,
                                    select: { selectSession(session) },
                                    togglePinned: { model.togglePinned(session.id) },
                                    toggleArchived: { model.toggleArchived(session.id) },
                                    isPinned: true,
                                    isArchived: false
                                )
                            }
                        }
                    }
                    if !needsAttention.isEmpty {
                        Section(AgentChatStrings.needsYourAttention) {
                            ForEach(needsAttention) { session in
                                AgentChatSessionRow(
                                    session: session,
                                    isSelected: session.id == model.selectedSessionID,
                                    select: { selectSession(session) },
                                    togglePinned: { model.togglePinned(session.id) },
                                    toggleArchived: { model.toggleArchived(session.id) },
                                    isPinned: false,
                                    isArchived: false
                                )
                            }
                        }
                    }
                    if !recentSessions.isEmpty {
                        Section(AgentChatStrings.recent) {
                        ForEach(recentSessions) { session in
                            AgentChatSessionRow(
                                session: session,
                                isSelected: session.id == model.selectedSessionID,
                                select: { selectSession(session) },
                                togglePinned: { model.togglePinned(session.id) },
                                toggleArchived: { model.toggleArchived(session.id) },
                                isPinned: false,
                                isArchived: false
                            )
                        }
                        }
                    }
                    if !model.visibleArchivedSessions.isEmpty {
                        Section(AgentChatStrings.archived) {
                            ForEach(model.visibleArchivedSessions) { session in
                                AgentChatSessionRow(
                                    session: session,
                                    isSelected: session.id == model.selectedSessionID,
                                    select: { selectSession(session) },
                                    togglePinned: { model.togglePinned(session.id) },
                                    toggleArchived: { model.toggleArchived(session.id) },
                                    isPinned: false,
                                    isArchived: true
                                )
                            }
                        }
                }
            }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, placement: .sidebar, prompt: AgentChatStrings.searchSessions)
            .refreshable { await refresh() }
        }
        .background(Color(.systemBackground))
        .accessibilityIdentifier("MobileAgentSessionsSidebar")
    }
}

private struct AgentSidebarHeader: View {
    @Binding var selectedProvider: String
    let showNewSessionComposer: () -> Void
    let refresh: () async -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(AgentChatStrings.agentHistory, systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button { showNewSessionComposer() } label: {
                    Label(AgentChatStrings.newSession, systemImage: "plus")
                }
                Button { Task { await refresh() } } label: {
                    Label(AgentChatStrings.refreshSessions, systemImage: "arrow.clockwise")
                }
                Divider()
                Picker(AgentChatStrings.provider, selection: $selectedProvider) {
                    Text(AgentChatStrings.allAgents).tag("all")
                    Text(AgentChatStrings.claudeCode).tag("claude")
                    Text(AgentChatStrings.codex).tag("codex")
                    Text(AgentChatStrings.openCode).tag("opencode")
                }
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
            }
            .accessibilityLabel(AgentChatStrings.newAgentSessionAndFilters)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

private struct AgentChatDetail: View {
    let store: CMUXMobileShellStore
    @Bindable var model: AgentChatModeModel
    let isLoading: Bool
    let isConnected: Bool
    let showSidebar: () -> Void
    let closeMode: () -> Void
    let refresh: () async -> Void
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingDelete = false
    @State private var exportedTranscript: ExportedTranscript?

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
        .navigationTitle(model.selectedSession?.title ?? AgentChatStrings.agents)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: showSidebar) {
                    Image(systemName: "sidebar.left")
                }
                .accessibilityLabel(AgentChatStrings.agentSessions)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await refresh() } } label: {
                        Label(AgentChatStrings.refresh, systemImage: "arrow.clockwise")
                    }
                    if model.selectedSession != nil {
                        Divider()
                        if model.selectedSession?.kind == .agent {
                            Button {
                                Task { await model.forkSelectedSession() }
                            } label: {
                                Label(
                                    model.isLaunchingSelectedSession ? AgentChatStrings.openingSideChat : AgentChatStrings.forkSideChat,
                                    systemImage: "arrow.triangle.branch"
                                )
                            }
                            .disabled(model.isLaunchingSelectedSession)
                            if model.selectedSession?.state == .ended {
                                Button {
                                    Task { await model.resumeSelectedSession() }
                                } label: {
                                    Label(AgentChatStrings.resumeSession, systemImage: "play.circle")
                                }
                                .disabled(model.isLaunchingSelectedSession)
                            } else {
                                Button {
                                    Task { await model.reopenSelectedSession() }
                                } label: {
                                    Label(AgentChatStrings.reopenInTerminal, systemImage: "rectangle.portrait.and.arrow.right")
                                }
                                .disabled(model.isLaunchingSelectedSession)
                            }
                        }
                        Button {
                            renameText = model.selectedSession?.title ?? ""
                            isRenaming = true
                        } label: {
                            Label(AgentChatStrings.renameSession, systemImage: "pencil")
                        }
                        Button {
                            Task {
                                if let text = await model.exportSelectedTranscript() {
                                    exportedTranscript = ExportedTranscript(text: text)
                                }
                            }
                        } label: {
                            Label(
                                model.exportingSessionIDs.contains(model.selectedSessionID ?? "")
                                    ? AgentChatStrings.exporting : AgentChatStrings.exportTranscript,
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .disabled(model.exportingSessionIDs.contains(model.selectedSessionID ?? ""))
                        Button(role: .destructive) {
                            isConfirmingDelete = true
                        } label: {
                            Label(AgentChatStrings.deleteSession, systemImage: "trash")
                        }
                    }
                    Button(action: closeMode) {
                        Label(AgentChatStrings.close, systemImage: "xmark")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel(AgentChatStrings.agentModeOptions)
            }
        }
        .alert(AgentChatStrings.renameSession, isPresented: $isRenaming) {
            TextField(AgentChatStrings.sessionName, text: $renameText)
            Button(AgentChatStrings.cancel, role: .cancel) {}
            Button(AgentChatStrings.rename) {
                Task { await model.renameSelectedSession(title: renameText) }
            }
        } message: {
            Text(AgentChatStrings.renameGuidance)
        }
        .confirmationDialog(
            AgentChatStrings.deleteSessionConfirmation,
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button(AgentChatStrings.delete, role: .destructive) {
                Task { await model.deleteSelectedSession() }
            }
            Button(AgentChatStrings.cancel, role: .cancel) {}
        } message: {
            Text(AgentChatStrings.deleteSessionGuidance)
        }
        .sheet(item: $exportedTranscript) { exported in
            NavigationStack {
                VStack(spacing: 16) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 34))
                        .foregroundStyle(.tint)
                    Text(AgentChatStrings.transcriptReadyToShare)
                        .font(.headline)
                    Text(AgentChatStrings.shareTranscriptGuidance)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    ShareLink(
                        item: exported.text,
                        subject: Text(AgentChatStrings.agentTranscript),
                        preview: SharePreview(AgentChatStrings.agentTranscript, image: Image(systemName: "doc.richtext"))
                    ) {
                        Label(AgentChatStrings.shareTranscript, systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .navigationTitle(AgentChatStrings.exportTranscript)
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
        }
    }
}

private struct ExportedTranscript: Identifiable {
    let id = UUID()
    let text: String
}

private struct AgentLoadingState: View {
    var body: some View {
        ContentUnavailableView {
            ProgressView()
                .controlSize(.large)
        } description: {
            Text(AgentChatStrings.loadingAgentSessions)
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
                isConnected ? AgentChatStrings.chooseAnAgentSession : AgentChatStrings.reconnectingToYourMac,
                systemImage: isConnected ? "sparkles" : "wifi.exclamationmark"
            )
        } description: {
            Text(isConnected
                ? AgentChatStrings.selectSessionGuidance
                : AgentChatStrings.historyUnavailableGuidance)
        } actions: {
            Button {
                Task { await refresh() }
            } label: {
                Label(AgentChatStrings.tryAgain, systemImage: "arrow.clockwise")
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
            Text(hasSearch ? AgentChatStrings.noMatchingSessions : (isConnected ? AgentChatStrings.noAgentSessionsYet : AgentChatStrings.waitingForConnection))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(hasSearch
                ? AgentChatStrings.searchNoMatchGuidance
                : (isConnected
                    ? AgentChatStrings.startSessionGuidance
                    : AgentChatStrings.reconnectHistoryGuidance))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if hasSearch {
                Button(AgentChatStrings.clearSearch, action: clearSearch)
                    .buttonStyle(.bordered)
            } else if isConnected {
                Button(AgentChatStrings.startNewSession, action: showNewSessionComposer)
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
            Text(AgentChatStrings.loadingSessions)
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
            Text(isConnected ? AgentChatStrings.connectedToYourMac : AgentChatStrings.reconnectingToYourMacWithEllipsis)
                .font(.caption.weight(.medium))
            Spacer(minLength: 8)
            if !isConnected {
                Button(AgentChatStrings.retry) { Task { await refresh() } }
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
    let togglePinned: () -> Void
    let toggleArchived: () -> Void
    let isPinned: Bool
    let isArchived: Bool

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Group {
                    if isKnownAgent {
                        TaskTemplateIcon(
                            value: "agent:\(session.agentKind.sourceName)",
                            size: 26
                        )
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(iconColor)
                    }
                }
                .frame(width: 28, height: 28)
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
        .contextMenu {
            Button(action: togglePinned) {
                Label(
                    isPinned ? AgentChatStrings.unpinSession : AgentChatStrings.pinSession,
                    systemImage: isPinned ? "pin.slash" : "pin"
                )
            }
            Button(action: toggleArchived) {
                Label(
                    isArchived ? AgentChatStrings.unarchiveSession : AgentChatStrings.archiveSession,
                    systemImage: isArchived ? "tray.and.arrow.up" : "archivebox"
                )
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(action: toggleArchived) {
                Label(
                    isArchived ? AgentChatStrings.unarchiveSession : AgentChatStrings.archiveSession,
                    systemImage: "archivebox"
                )
            }
            .tint(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            AgentChatStrings.sessionAccessibility(
                agent: session.agentKind.displayName,
                title: session.title ?? AgentChatStrings.untitledSession,
                state: accessibilityStateLabel
            )
        )
    }

    private var isKnownAgent: Bool {
        switch session.agentKind.sourceName {
        case "claude", "codex", "opencode": return true
        default: return false
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

    private var accessibilityStateLabel: String {
        switch session.state {
        case .working: return AgentChatStrings.working
        case .needsInput: return AgentChatStrings.needsInput
        case .failed: return AgentChatStrings.turnFailedRetryAvailable
        case .idle: return AgentChatStrings.idle
        case .ended: return AgentChatStrings.ended
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
        case .working: return AgentChatStrings.working
        case .needsInput: return AgentChatStrings.needsInput
        case .failed: return AgentChatStrings.turnFailedRetryAvailable
        case .idle: return AgentChatStrings.idle
        case .ended: return AgentChatStrings.ended
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
                if case .needsInput = session.state {
                    AgentNeedsInputNotice(actionableCount: model.selectedPendingActionableCount)
                }
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
                let artifactLoader = model.selectedSessionID.flatMap { model.artifactLoader(for: $0) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let usage = model.selectedUsage {
                            AgentUsageContextCard(totals: usage)
                        }
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
                                Label(AgentChatStrings.loadEarlierMessages, systemImage: "chevron.up")
                                    .font(.footnote.weight(.medium))
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .padding(.bottom, 2)
                        }
                        if model.selectedMessages.isEmpty,
                           model.selectedTerminalBlocks.isEmpty,
                           model.selectedStreamingMessage == nil,
                           model.selectedPendingPrompts.isEmpty {
                            ContentUnavailableView(AgentChatStrings.startTask, systemImage: "sparkles", description: Text(AgentChatStrings.startTaskGuidance))
                                .padding(.top, 80)
                        } else {
                            if model.selectedSession?.kind == .terminal {
                                ForEach(model.selectedTerminalBlocks) { block in
                                    AgentTerminalBlockView(block: block)
                                        .id("terminal-\(block.id)")
                                }
                            }
                            let latestEditablePromptID = model.selectedMessages.last(where: { message in
                                guard message.role == .user else { return false }
                                if case .prose = message.kind { return true }
                                return false
                            })?.id
                            let latestAgentResponseID = model.latestAgentResponseID
                            let isRegenerating = model.selectedSessionID.map {
                                model.regeneratingSessionIDs.contains($0)
                            } == true
                            ForEach(model.selectedMessages) { message in
                                AgentChatMessageView(
                                    message: message,
                                    artifactLoader: artifactLoader,
                                    answer: { index, requestID in
                                        Task { await model.answer(optionIndex: index, requestID: requestID) }
                                    },
                                    answerSelections: { indexes, requestID in
                                        Task { await model.answer(optionIndexes: indexes, requestID: requestID) }
                                    },
                                    answerText: { text, requestID in
                                        Task { await model.answer(text: text, requestID: requestID) }
                                    },
                                    isAnswering: { model.isAnswering(requestID: $0) },
                                    review: { action, lineNumber, comment in
                                        guard case .fileEdit(let edit) = message.kind else { return }
                                        Task {
                                            await model.review(
                                                messageID: message.id,
                                                action: action,
                                                filePath: edit.filePath,
                                                unifiedDiff: edit.unifiedDiff,
                                                lineNumber: lineNumber,
                                                comment: comment
                                            )
                                        }
                                    },
                                    isReviewing: { model.isReviewing(messageID: message.id) },
                                    edit: message.id == latestEditablePromptID
                                        ? {
                                            model.editPrompt(message)
                                            composerFocused = true
                                        }
                                        : nil,
                                    regenerate: message.id == latestAgentResponseID
                                        ? { Task { await model.regenerateLatestResponse() } }
                                        : nil,
                                    isRegenerating: message.id == latestAgentResponseID
                                        && isRegenerating,
                                    canRegenerate: message.id == latestAgentResponseID
                                        && (model.canRegenerateLatestResponse || isRegenerating)
                                )
                                .id(message.id)
                            }
                            let pendingPrompts = model.selectedPendingPrompts
                            let sendingPromptCount = pendingPrompts.count - model.queuedSendCount
                            ForEach(Array(pendingPrompts.enumerated()), id: \.offset) { index, prompt in
                                AgentPendingPromptBubble(
                                    text: prompt,
                                    isQueued: index >= sendingPromptCount
                                )
                                .id("pending-\(index)-\(prompt)")
                            }
                            if let streaming = model.selectedStreamingMessage {
                                AgentChatMessageView(
                                    message: streaming,
                                    artifactLoader: artifactLoader,
                                    isStreaming: true
                                )
                                    .id("streaming")
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 18)
                }
                .defaultScrollAnchor(.bottom)
                .accessibilityIdentifier("MobileAgentTranscript")
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
                .onChange(of: model.selectedPendingPrompts.count) { oldCount, newCount in
                    guard newCount > oldCount else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .refreshable { await model.refresh() }
            }
            AgentChatComposer(store: store, model: model, focused: $composerFocused)
        }
        .background(Color(.systemBackground))
        .accessibilityIdentifier("MobileAgentConversation")
    }
}

private struct AgentPendingPromptBubble: View {
    let text: String
    let isQueued: Bool

    var body: some View {
        HStack {
            Spacer(minLength: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(text.isEmpty ? AgentChatStrings.attachment : text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                Label(
                    isQueued ? AgentChatStrings.queuedForNextTurn : AgentChatStrings.sending,
                    systemImage: isQueued ? "clock.arrow.circlepath" : "arrow.up.circle"
                )
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isQueued
            ? AgentChatStrings.queuedAccessibility(text.isEmpty ? AgentChatStrings.attachment : text)
            : AgentChatStrings.sendingAccessibility(text.isEmpty ? AgentChatStrings.attachment : text))
    }
}

private struct AgentNeedsInputNotice: View {
    let actionableCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(AgentChatStrings.yourInputIsNeeded)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileAgentNeedsInputNotice")
    }

    private var detail: String {
        switch actionableCount {
        case 0: return AgentChatStrings.answerOrApproveGuidance
        case 1: return AgentChatStrings.reviewPendingRequestGuidance
        default: return AgentChatStrings.pendingRequests(actionableCount)
        }
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
                Text(AgentChatStrings.turnFailed)
                    .font(.subheadline.weight(.semibold))
                if let reason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else {
                    Text(AgentChatStrings.agentDidNotCompleteTurn)
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
                    Label(AgentChatStrings.retry, systemImage: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!canRetry || isRetrying)
            .accessibilityLabel(isRetrying ? AgentChatStrings.retryingFailedTurn : AgentChatStrings.retryFailedTurn)
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
        HStack(spacing: 8) {
            if ["claude", "codex", "opencode"].contains(session.agentKind.sourceName) {
                TaskTemplateIcon(value: "agent:\(session.agentKind.sourceName)", size: 18)
            } else {
                Image(systemName: "sparkles")
            }
            Text(session.agentKind.displayName)
                .font(.subheadline.weight(.medium))
            if let directory = session.workingDirectory, !directory.isEmpty {
                Label(URL(fileURLWithPath: directory).lastPathComponent, systemImage: "folder")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(directory)
            }
            Spacer(minLength: 4)
            AgentStatusIndicator(state: session.state)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}

private struct AgentSessionControlsMenu: View {
    @Bindable var model: AgentChatModeModel

    private var hasControls: Bool {
        let controls = model.selectedControls
        return controls.supportsPlanMode || !controls.modelOptions.isEmpty
            || !controls.reasoningEffortOptions.isEmpty || !controls.permissionOptions.isEmpty
            || !controls.sandboxOptions.isEmpty
    }

    var body: some View {
        if hasControls {
            Menu {
                let controls = model.selectedControls
                if !controls.modelOptions.isEmpty {
                    Menu(AgentChatStrings.model) {
                        ForEach(controls.modelOptions) { option in
                            Button {
                                var next = model.selectedControls
                                next.modelID = option.id
                                next.reasoningEffortID = nil
                                Task { await model.updateSelectedControls(next) }
                            } label: {
                                Label(option.displayName, systemImage: controls.modelID == option.id ? "checkmark" : "")
                            }
                        }
                    }
                }
                if !controls.reasoningEffortOptions.isEmpty {
                    Menu(AgentChatStrings.reasoningEffort) {
                        ForEach(controls.reasoningEffortOptions) { option in
                            Button {
                                var next = model.selectedControls
                                next.reasoningEffortID = option.id
                                Task { await model.updateSelectedControls(next) }
                            } label: {
                                Label(option.displayName, systemImage: controls.reasoningEffortID == option.id ? "checkmark" : "")
                            }
                        }
                    }
                }
                if !controls.permissionOptions.isEmpty {
                    Menu(AgentChatStrings.permissionMode) {
                        ForEach(controls.permissionOptions) { option in
                            Button {
                                var next = model.selectedControls
                                next.permissionMode = option.id
                                Task { await model.updateSelectedControls(next) }
                            } label: {
                                Label(option.displayName, systemImage: controls.permissionMode == option.id ? "checkmark" : "")
                            }
                        }
                    }
                }
                if !controls.sandboxOptions.isEmpty {
                    Menu(AgentChatStrings.sandbox) {
                        ForEach(controls.sandboxOptions) { option in
                            Button {
                                var next = model.selectedControls
                                next.sandboxMode = option.id
                                Task { await model.updateSelectedControls(next) }
                            } label: {
                                Label(option.displayName, systemImage: controls.sandboxMode == option.id ? "checkmark" : "")
                            }
                        }
                    }
                }
                if controls.supportsPlanMode {
                    Toggle(isOn: Binding(
                        get: { model.selectedControls.planMode },
                        set: { value in
                            var next = model.selectedControls
                            next.planMode = value
                            Task { await model.updateSelectedControls(next) }
                        }
                    )) {
                        Label(AgentChatStrings.planMode, systemImage: "list.bullet.clipboard")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    if let option = model.selectedControls.modelOptions.first(where: {
                        $0.id == model.selectedControls.modelID
                    }) {
                        Text(option.displayName)
                        if let effort = model.selectedControls.reasoningEffortOptions.first(where: {
                            $0.id == model.selectedControls.reasoningEffortID
                        }) {
                            Text(effort.displayName).foregroundStyle(.secondary)
                        }
                    } else {
                        Label(AgentChatStrings.controls, systemImage: "slider.horizontal.3")
                    }
                }
                .font(.subheadline)
                .lineLimit(1)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(model.selectedSession == nil || model.selectedSession?.state == .ended
                || model.updatingControlsSessionIDs.contains(model.selectedSessionID ?? ""))
            .accessibilityIdentifier("MobileAgentSessionControls")
        }
    }
}

private struct AgentChatMessageView: View {
    let message: ChatMessage
    let artifactLoader: ChatArtifactLoader?
    var isStreaming = false
    var answer: ((Int, String) -> Void)?
    var answerSelections: (([Int], String) -> Void)?
    var answerText: ((String, String) -> Void)?
    var isAnswering: ((String) -> Bool)?
    var review: ((ChatReviewAction, Int?, String?) -> Void)?
    var isReviewing: (() -> Bool)?
    var edit: (() -> Void)?
    var regenerate: (() -> Void)? = nil
    var isRegenerating = false
    var canRegenerate = false

    var body: some View {
        Group {
            switch message.kind {
            case .prose(let prose):
                AgentProseBubble(text: prose.text, role: message.role, isStreaming: isStreaming)
            case .thought(let thought):
                AgentThoughtCard(text: thought.text)
            case .toolUse(let tool):
                AgentToolCard(tool: tool)
            case .webSearch(let search):
                AgentWebSearchCard(search: search)
            case .terminal(let terminal):
                AgentTerminalCard(terminal: terminal)
            case .fileEdit(let edit):
                AgentDiffCard(
                    edit: edit,
                    artifactLoader: artifactLoader,
                    review: review,
                    isReviewing: isReviewing?() == true
                )
            case .permissionRequest(let request):
                AgentPermissionCard(
                    request: request,
                    isSubmitting: isAnswering?(message.id) == true,
                    answer: { index in answer?(index, message.id) }
                )
            case .question(let question):
                AgentQuestionCard(
                    question: question,
                    isSubmitting: isAnswering?(message.id) == true,
                    answer: { index in answer?(index, message.id) },
                    answerSelections: { indexes in answerSelections?(indexes, message.id) },
                    answerText: { text in answerText?(text, message.id) }
                )
            case .status(let status):
                AgentStatusCard(status: status, timestamp: message.timestamp)
            case .attachment(let attachment):
                AgentAttachmentCard(attachment: attachment, artifactLoader: artifactLoader)
            case .unsupported(let payload):
                Label(AgentChatStrings.unsupportedEvent(payload.rawType), systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .agentMessageActions(
            copying: copyText,
            editing: edit,
            regenerating: isRegenerating,
            regenerate: regenerate,
            canRegenerate: canRegenerate
        )
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
            if let input = tool.inputDetail, !input.isEmpty {
                lines.append("\(AgentChatStrings.input):\n\(input)")
            }
            if let paths = tool.referencedPaths, !paths.isEmpty { lines.append(paths.joined(separator: "\n")) }
            if let output = tool.output, !output.isEmpty {
                lines.append("\(AgentChatStrings.output):\n\(output)")
            }
            return lines.joined(separator: "\n")
        case .webSearch(let search):
            var lines = [search.query.map { AgentChatStrings.searchQuery($0) } ?? AgentChatStrings.sources]
            lines.append(contentsOf: search.sources.map { source in
                [source.title, source.url, source.snippet].compactMap { $0 }.joined(separator: "\n")
            })
            return lines.joined(separator: "\n\n")
        case .terminal(let terminal):
            var lines = [terminal.command]
            if let output = terminal.output, !output.isEmpty { lines.append(output) }
            if let exitCode = terminal.exitCode { lines.append(AgentChatStrings.exitCode(exitCode)) }
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
    let edit: (() -> Void)?
    let regenerating: Bool
    let regenerate: (() -> Void)?
    let canRegenerate: Bool

    func body(content: Content) -> some View {
        guard (copyText?.isEmpty == false) || edit != nil || regenerate != nil else {
            return AnyView(content)
        }
        return AnyView(
            content
                .contextMenu {
                    if let edit {
                        Button(action: edit) {
                            Label(AgentChatStrings.editPrompt, systemImage: "pencil")
                        }
                    }
                    if let regenerate {
                        Button(action: regenerate) {
                            Label(
                                regenerating ? AgentChatStrings.regeneratingResponse : AgentChatStrings.regenerateResponse,
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .disabled(regenerating || !canRegenerate)
                    }
                    if let copyText, !copyText.isEmpty {
                        Button {
                            UIPasteboard.general.string = copyText
                        } label: {
                            Label(AgentChatStrings.copy, systemImage: "doc.on.doc")
                        }
                        ShareLink(item: copyText) {
                            Label(AgentChatStrings.share, systemImage: "square.and.arrow.up")
                        }
                    }
                }
                .accessibilityAction(named: Text(AgentChatStrings.copy)) {
                    if let copyText, !copyText.isEmpty {
                        UIPasteboard.general.string = copyText
                    }
                }
                .accessibilityAction(named: Text(AgentChatStrings.regenerateResponse)) {
                    guard !regenerating, canRegenerate else { return }
                    regenerate?()
                }
        )
    }
}

private extension View {
    func agentMessageActions(
        copying text: String?,
        editing edit: (() -> Void)? = nil,
        regenerating: Bool = false,
        regenerate: (() -> Void)? = nil,
        canRegenerate: Bool = false
    ) -> some View {
        modifier(AgentMessageActions(
            copyText: text,
            edit: edit,
            regenerating: regenerating,
            regenerate: regenerate,
            canRegenerate: canRegenerate
        ))
    }
}

private struct AgentProseBubble: View {
    let text: String
    let role: ChatRole
    let isStreaming: Bool

    var body: some View {
        HStack {
            if role == .user { Spacer(minLength: 36) }
            AgentMarkdownView(markdown: text, color: .primary)
                .padding(.horizontal, role == .user ? 14 : 0)
                .padding(.vertical, 11)
                .background(role == .user ? Color(.secondarySystemBackground) : Color.clear, in: RoundedRectangle(cornerRadius: 22))
                .foregroundStyle(.primary)
                .opacity(isStreaming ? 0.9 : 1)
        }
    }
}

private struct AgentTerminalBlockView: View {
    let block: TerminalCommandBlock

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: block.isInteractive ? "rectangle.inset.filled" : "terminal")
                Text(block.command.isEmpty ? AgentChatStrings.shell : block.command)
                    .font(.caption.monospaced().weight(.semibold))
                    .lineLimit(2)
                Spacer()
                if block.isRunning {
                    ProgressView().controlSize(.mini)
                } else if let exitCode = block.exitCode {
                    Text(AgentChatStrings.exitCode(exitCode))
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
        if let exitCode = block.exitCode { lines.append(AgentChatStrings.exitCode(exitCode)) }
        return lines.joined(separator: "\n")
    }
}

private struct AgentThoughtCard: View {
    let text: String
    var body: some View {
        DisclosureGroup(AgentChatStrings.thinking) { Text(text).font(.caption).foregroundStyle(.secondary) }
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
            HStack(spacing: 8) {
                Label(tool.summary, systemImage: iconName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(statusColor)
                Spacer(minLength: 4)
                Text(statusLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor)
            }
            if let inputDetail = tool.inputDetail,
               !inputDetail.isEmpty {
                DisclosureGroup(AgentChatStrings.input, isExpanded: $isInputExpanded) {
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
                DisclosureGroup(AgentChatStrings.output, isExpanded: $isOutputExpanded) {
                    Text(output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .font(.caption.weight(.medium))
            }
            if tool.status == .running {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(AgentChatStrings.toolIsRunning)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileAgentToolCard")
    }

    private var iconName: String {
        switch tool.status {
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var statusLabel: String {
        switch tool.status {
        case .running: return AgentChatStrings.running
        case .succeeded: return AgentChatStrings.done
        case .failed: return AgentChatStrings.failed
        }
    }

    private var statusColor: Color {
        switch tool.status {
        case .running: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}

private struct AgentWebSearchCard: View {
    let search: ChatWebSearch

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .foregroundStyle(statusColor)
                Text(search.query.map { AgentChatStrings.searchQuery($0) } ?? AgentChatStrings.sources)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Text(statusLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor)
            }
            if search.sources.isEmpty {
                Text(AgentChatStrings.noSourcesReturned)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(search.sources) { source in
                    if let url = URL(string: source.url) {
                        Link(destination: url) {
                            sourceRow(source)
                        }
                        .buttonStyle(.plain)
                    } else {
                        sourceRow(source)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileAgentWebSearchCard")
    }

    @ViewBuilder
    private func sourceRow(_ source: ChatWebSearch.Source) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "link")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.title?.isEmpty == false ? source.title! : source.url)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let snippet = source.snippet, !snippet.isEmpty {
                    Text(snippet)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if source.title?.isEmpty == false {
                    Text(source.url)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }

    private var statusLabel: String {
        switch search.status {
        case .running: return AgentChatStrings.searching
        case .succeeded: return search.sources.isEmpty ? AgentChatStrings.done : AgentChatStrings.sources
        case .failed: return AgentChatStrings.failed
        }
    }

    private var statusColor: Color {
        switch search.status {
        case .running: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        }
    }
}

private struct AgentTerminalCard: View {
    let terminal: ChatTerminalCapture
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(terminal.command, systemImage: terminal.isRunning ? "arrow.triangle.2.circlepath" : "terminal")
                    .font(.caption.monospaced().weight(.semibold))
                Spacer(minLength: 4)
                if terminal.isRunning {
                    ProgressView().controlSize(.mini)
                    Text(AgentChatStrings.running)
                } else if let exitCode = terminal.exitCode {
                    Text(AgentChatStrings.exitCode(exitCode))
                        .foregroundStyle(exitCode == 0 ? .green : .red)
                } else {
                    Text(AgentChatStrings.done).foregroundStyle(.secondary)
                }
            }
            if let output = terminal.output { Text(output).font(.caption.monospaced()).textSelection(.enabled) }
            if let duration = terminal.durationSeconds {
                Text(durationLabel(duration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.92), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileAgentTerminalCard")
    }

    private func durationLabel(_ duration: Double) -> String {
        if duration < 1 { return String(format: "%.0f ms", duration * 1_000) }
        if duration < 60 { return String(format: "%.1f s", duration) }
        return String(format: "%.1f min", duration / 60)
    }
}

private struct AgentStatusCard: View {
    let status: ChatStatusTransition
    let timestamp: Date

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                if let detail = status.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Text(timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.09), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("MobileAgentStatusCard")
    }

    private var title: String {
        switch status.event {
        case .sessionStarted: return AgentChatStrings.sessionStarted
        case .sessionEnded: return AgentChatStrings.sessionEndedStatus
        case .interrupted: return AgentChatStrings.turnInterrupted
        case .contextCompacted: return AgentChatStrings.contextCompacted
        }
    }

    private var iconName: String {
        switch status.event {
        case .sessionStarted: return "play.circle.fill"
        case .sessionEnded: return "checkmark.circle.fill"
        case .interrupted: return "stop.circle.fill"
        case .contextCompacted: return "arrow.down.right.and.arrow.up.left"
        }
    }

    private var color: Color {
        switch status.event {
        case .sessionStarted: return .green
        case .sessionEnded: return .secondary
        case .interrupted: return .orange
        case .contextCompacted: return .accentColor
        }
    }
}

private struct AgentDiffCard: View {
    let edit: ChatFileEdit
    let artifactLoader: ChatArtifactLoader?
    let review: ((ChatReviewAction, Int?, String?) -> Void)?
    let isReviewing: Bool
    @State private var isExpanded = false
    @State private var isCommentExpanded = false
    @State private var lineNumber = ""
    @State private var comment = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(edit.filePath, systemImage: operationIcon)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(operationLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(operationColor)
                if let additions = edit.additions { Text("+\(additions)").foregroundStyle(.green) }
                if let deletions = edit.deletions { Text("-\(deletions)").foregroundStyle(.red) }
            }
            if let diff = edit.unifiedDiff {
                DisclosureGroup(AgentChatStrings.viewDiff, isExpanded: $isExpanded) {
                    Text(diff)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(isExpanded ? nil : 12)
                }
                .font(.caption.weight(.medium))

                if let review {
                    HStack(spacing: 8) {
                        Button {
                            review(.apply, nil, nil)
                        } label: {
                            Label(AgentChatStrings.apply, systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("MobileAgentDiffApply")

                        Button {
                            review(.revert, nil, nil)
                        } label: {
                            Label(AgentChatStrings.revert, systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("MobileAgentDiffRevert")
                        Spacer(minLength: 0)
                    }
                    .disabled(isReviewing)

                    DisclosureGroup(AgentChatStrings.commentOnLine, isExpanded: $isCommentExpanded) {
                        HStack(spacing: 8) {
                            TextField(AgentChatStrings.line, text: $lineNumber)
                                .keyboardType(.numberPad)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                            TextField(AgentChatStrings.reviewComment, text: $comment, axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(2...4)
                            Button(AgentChatStrings.send) {
                                guard let line = Int(lineNumber), line > 0,
                                      !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                review(.comment, line, comment.trimmingCharacters(in: .whitespacesAndNewlines))
                                comment = ""
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityIdentifier("MobileAgentDiffCommentSend")
                        }
                    }
                    .font(.caption.weight(.medium))
                    .disabled(isReviewing)
                }
            } else {
                Label(AgentChatStrings.diffUnavailable, systemImage: "exclamationmark.triangle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(AgentChatStrings.diffMissingGuidance)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isExpanded, let artifactLoader, artifactLoader.supportsArtifacts {
                Divider()
                Text(AgentChatStrings.currentFile)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ChatArtifactInlineViewer(path: edit.filePath)
                    .environment(\.chatArtifactLoader, artifactLoader)
                    .frame(minHeight: 160, maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .font(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileAgentDiffCard")
    }

    private var operationLabel: String {
        switch edit.operation {
        case .edit: return AgentChatStrings.edited
        case .write: return AgentChatStrings.created
        case .delete: return AgentChatStrings.deleted
        }
    }

    private var operationIcon: String {
        switch edit.operation {
        case .edit: return "doc.text"
        case .write: return "doc.badge.plus"
        case .delete: return "doc.badge.minus"
        }
    }

    private var operationColor: Color {
        edit.operation == .delete ? .red : .secondary
    }
}

private struct AgentAttachmentCard: View {
    let attachment: ChatAttachment
    let artifactLoader: ChatArtifactLoader?
    @State private var isPreviewExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: attachment.media == .image ? "photo" : "doc")
                    .foregroundStyle(Color.accentColor)
                Text(attachment.displayName ?? AgentChatStrings.attachment)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if attachment.hostPath != nil,
                   let artifactLoader,
                   artifactLoader.supportsArtifacts {
                    Button(isPreviewExpanded ? AgentChatStrings.hidePreview : AgentChatStrings.preview) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isPreviewExpanded.toggle()
                        }
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            if isPreviewExpanded,
               let path = attachment.hostPath,
               let artifactLoader {
                ChatArtifactInlineViewer(path: path)
                    .environment(\.chatArtifactLoader, artifactLoader)
                    .frame(minHeight: 160, maxHeight: 420)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AgentPermissionCard: View {
    let request: ChatPermissionRequest
    let isSubmitting: Bool
    let answer: ((Int) -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(request.title, systemImage: "hand.raised.fill")
                .font(.headline)
            if isSubmitting {
                Label(AgentChatStrings.sendingDecision, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(request.subject).font(.caption.monospaced()).textSelection(.enabled)
            if let scope = request.scope, !scope.isEmpty {
                Label(AgentChatStrings.scope(scope), systemImage: "scope")
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
        case .approved: return AgentChatStrings.allowedOnce
        case .approvedAlways: return AgentChatStrings.alwaysAllowed
        case .approvedAll: return AgentChatStrings.allMatchingActionsAllowed
        case .denied: return AgentChatStrings.denied
        case .expired: return AgentChatStrings.expired
        }
    }

    @ViewBuilder
    private func permissionButton(index: Int, option: ChatPermissionRequest.Option) -> some View {
        if isDestructive(option) {
            Button(action: { answer?(index) }) {
                permissionButtonLabel(option)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(isSubmitting)
        } else {
            Button(action: { answer?(index) }) {
                permissionButtonLabel(option)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting)
        }
    }

    private func isDestructive(_ option: ChatPermissionRequest.Option) -> Bool {
        let label = option.label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return ["deny", "reject", "block", "don't allow", "do not allow"].contains {
            label.contains($0)
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
    let isSubmitting: Bool
    let answer: ((Int) -> Void)?
    let answerSelections: (([Int]) -> Void)?
    let answerText: ((String) -> Void)?
    @State private var selectedIndexes: Set<Int> = []
    @State private var freeText = ""

    init(
        question: ChatQuestion,
        isSubmitting: Bool,
        answer: ((Int) -> Void)?,
        answerSelections: (([Int]) -> Void)?,
        answerText: ((String) -> Void)?
    ) {
        self.question = question
        self.isSubmitting = isSubmitting
        self.answer = answer
        self.answerSelections = answerSelections
        self.answerText = answerText
        let labels = Set(question.selectedOptionLabels)
        _selectedIndexes = State(initialValue: Set(question.options.indices.filter { labels.contains(question.options[$0].label) }))
    }

    private var isPlanReview: Bool {
        let labels = question.options.map { $0.label.lowercased() }
        return labels.contains(where: { $0.contains("approve plan") })
            && labels.contains(where: { $0.contains("reject plan") })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isPlanReview {
                Label(AgentChatStrings.planReadyForReview, systemImage: "checklist")
                    .font(.headline)
            }
            if isSubmitting {
                Label(AgentChatStrings.sendingAnswer, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(question.prompt).font(isPlanReview ? .body : .headline)
            if let selected = question.selectedOptionLabel {
                Label(AgentChatStrings.answered(selected), systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                    optionButton(index: index, option: option)
                }
                if question.multiSelect {
                    Button {
                        answerSelections?(selectedIndexes.sorted())
                    } label: {
                        Label(AgentChatStrings.submitSelection, systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIndexes.isEmpty || isSubmitting)
                }
                HStack(spacing: 8) {
                    TextField(AgentChatStrings.typeAnAnswer, text: $freeText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isSubmitting)
                    Button(AgentChatStrings.send) {
                        answerText?(freeText.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                    .buttonStyle(.bordered)
                    .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
        .onChange(of: question) { _, newQuestion in
            let labels = Set(newQuestion.selectedOptionLabels)
            selectedIndexes = Set(newQuestion.options.indices.filter { labels.contains(newQuestion.options[$0].label) })
            freeText = ""
        }
    }

    @ViewBuilder
    private func optionButton(index: Int, option: ChatQuestion.Option) -> some View {
        let button = Button {
            if question.multiSelect {
                if selectedIndexes.contains(index) {
                    selectedIndexes.remove(index)
                } else {
                    selectedIndexes.insert(index)
                }
            } else {
                answer?(index)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(option.label).font(.subheadline.weight(.semibold))
                if let detail = option.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .trailing) {
            if question.multiSelect && selectedIndexes.contains(index) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .padding(.trailing, 10)
            }
        }
        if index == 0 && isPlanReview {
            button
                .buttonStyle(.borderedProminent)
                .disabled((!question.multiSelect && question.selectedOptionLabel != nil) || isSubmitting)
        } else {
            button
                .buttonStyle(.bordered)
                    .disabled((!question.multiSelect && question.selectedOptionLabel != nil) || isSubmitting)
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
    @State private var isFileImporterPresented = false
    @State private var attachmentStagingTask: Task<Void, Never>?
    @State private var attachmentErrorMessage: String?
    @State private var previewAttachment: AgentChatModeModel.PendingAttachment?
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
            if !model.attachmentStaging.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(AgentChatStrings.preparingAttachments(model.attachmentStaging.count))
                            .font(.caption.weight(.medium))
                        Spacer(minLength: 0)
                        Button(AgentChatStrings.cancel) {
                            attachmentStagingTask?.cancel()
                            model.cancelAttachmentStaging()
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("MobileAgentAttachmentCancel")
                    }
                    ForEach(model.attachmentStaging) { item in
                        AgentAttachmentStagingRow(item: item)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .accessibilityElement(children: .contain)
            }
            if let attachmentErrorMessage {
                HStack(alignment: .top, spacing: 7) {
                    Label(attachmentErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer(minLength: 0)
                    if !photoSelection.isEmpty {
                        Button(AgentChatStrings.retry) {
                            Task { await stagePhotos(photoSelection) }
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
                .padding(.horizontal, 6)
                .accessibilityElement(children: .combine)
            }
            if dictation.state != .idle {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: dictation.state == .unavailable
                        ? "mic.slash.fill"
                        : (dictation.state.isListening ? "mic.fill" : "mic"))
                        .foregroundStyle(dictation.state == .unavailable ? .red : .secondary)
                    Text(dictationStatusText)
                        .font(.caption)
                    Spacer(minLength: 0)
                    if dictation.state == .unavailable {
                        Button(AgentChatStrings.settings) { openDictationSettings() }
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(.horizontal, 6)
                .accessibilityElement(children: .combine)
            }
            if model.queuedSendCount > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text(AgentChatStrings.queuedMessages(model.queuedSendCount))
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
                            } preview: {
                                previewAttachment = attachment
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField(
                    isSessionEnded ? AgentChatStrings.sessionEndedStatus : AgentChatStrings.messageYourAgent,
                    text: $model.draft,
                    axis: .vertical
                )
                    .lineLimit(1...6)
                    .accessibilityIdentifier("MobileAgentComposerInput")
                    .focused(focused)
                    .textFieldStyle(.plain)
                    .padding(.vertical, 10)
                    .disabled(isSessionEnded)
                    .disabled(dictation.locksComposerField)
                    .onChange(of: focused.wrappedValue) { _, isFocused in
                        guard !isFocused, !dictation.locksComposerField else { return }
                        dictation.stop()
                    }
                HStack(spacing: 10) {
                    Menu {
                        Button {
                            isPhotoPickerPresented = true
                        } label: {
                            Label(AgentChatStrings.photoLibrary, systemImage: "photo.on.rectangle")
                        }
                        Button {
                            startAttachmentStaging { await model.stagePastedImages() }
                        } label: {
                            Label(AgentChatStrings.pasteImage, systemImage: "doc.on.clipboard")
                        }
                        Button {
                            isFileImporterPresented = true
                        } label: {
                            Label(AgentChatStrings.chooseFile, systemImage: "doc")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(AgentChatStrings.addAttachment)
                    .disabled(isSessionEnded || model.attachments.count >= 10)
                    Spacer(minLength: 0)
                    AgentSessionControlsMenu(model: model)
                    Button {
                        toggleDictation()
                    } label: {
                        Image(systemName: dictation.state.isListening ? "mic.fill" : "mic")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                    }
                    .foregroundStyle(dictation.state.isListening ? .red : .secondary)
                    .symbolEffect(.pulse, isActive: dictation.state.isListening)
                    .disabled(isSessionEnded || !dictation.isAvailable)
                    .accessibilityLabel(
                        dictation.state.isListening ? AgentChatStrings.stopDictation : AgentChatStrings.startDictation
                    )
                    .accessibilityIdentifier("MobileAgentComposerMic")
                    if model.selectedSession?.isWorking == true {
                        Menu {
                            Button {
                                Task { await model.interrupt() }
                            } label: {
                                Label(AgentChatStrings.stopTurn, systemImage: "stop.circle")
                            }
                            Button(role: .destructive) {
                                Task { await model.interrupt(hard: true) }
                            } label: {
                                Label(AgentChatStrings.forceStop, systemImage: "exclamationmark.octagon")
                            }
                        } label: {
                            if model.interruptingSessionIDs.contains(model.selectedSessionID ?? "") {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "stop.circle.fill")
                                    .font(.system(size: 30))
                                    .frame(width: 44, height: 44)
                            }
                        }
                        .foregroundStyle(.primary)
                        .accessibilityLabel(AgentChatStrings.stopAgent)
                        .accessibilityHint(AgentChatStrings.stopAgentGuidance)
                        .disabled(isSessionEnded || model.interruptingSessionIDs.contains(model.selectedSessionID ?? ""))
                    }
                    if model.selectedSession?.isWorking == true {
                        Menu {
                            Button {
                                dictation.cancel()
                                Task { await model.sendDraft() }
                            } label: {
                                Label(AgentChatStrings.queueForNextTurn, systemImage: "clock.arrow.circlepath")
                            }
                            Button {
                                dictation.cancel()
                                Task { await model.steerDraft() }
                            } label: {
                                Label(AgentChatStrings.steerCurrentTurn, systemImage: "arrow.uturn.forward")
                            }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .frame(width: 44, height: 44)
                        }
                        .foregroundStyle(canSend ? Color.primary : Color.secondary)
                        .disabled(!canSend)
                        .accessibilityLabel(AgentChatStrings.sendInstruction)
                        .accessibilityHint(AgentChatStrings.sendInstructionGuidance)
                    } else {
                        Button {
                            dictation.cancel()
                            Task { await model.sendDraft() }
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .frame(width: 44, height: 44)
                        }
                        .foregroundStyle(canSend ? Color.primary : Color.secondary)
                        .disabled(!canSend)
                        .accessibilityLabel(AgentChatStrings.send)
                        .accessibilityIdentifier("MobileAgentComposerSend")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 28))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileAgentComposer")
        .accessibilityHint(isSessionEnded ? AgentChatStrings.readOnlySession : "")
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $photoSelection,
            maxSelectionCount: max(1, 10 - model.attachments.count),
            matching: .images
        )
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                startAttachmentStaging { await stageFiles(urls) }
            case .failure(let error):
                attachmentErrorMessage = error.localizedDescription
            }
        }
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            startAttachmentStaging { await stagePhotos(items) }
        }
        .onChange(of: model.selectedSessionID) { _, _ in
            // Session selection resets the draft and transcript source. Stop
            // any in-flight recognizer before those state changes can route a
            // late partial into the newly selected session.
            dictation.cancel()
            attachmentStagingTask?.cancel()
            model.cancelAttachmentStaging()
            model.endAttachmentStaging()
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
            attachmentStagingTask?.cancel()
            model.cancelAttachmentStaging()
        }
        .sheet(item: $previewAttachment) { attachment in
            AgentAttachmentPreview(attachment: attachment)
        }
    }

    private var canSend: Bool {
        !isSessionEnded
            && (!model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.attachments.isEmpty)
    }

    /// Keeps a handle to the current import so the composer can cancel a
    /// multi-selection without waiting for every provider callback to return.
    /// The model owns the visible per-file state; this task only controls the
    /// lifetime of the underlying PhotosUI/FileProvider work.
    private func startAttachmentStaging(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        attachmentStagingTask?.cancel()
        attachmentStagingTask = Task { @MainActor in
            await operation()
        }
    }

    private func stagePhotos(_ items: [PhotosPickerItem]) async {
        let remaining = max(0, 10 - model.attachments.count)
        guard remaining > 0 else { return }
        attachmentErrorMessage = nil
        var failures = 0
        let selected = Array(items.prefix(remaining))
        let stages = selected.enumerated().map { index, _ in
            AgentChatModeModel.AttachmentStagingItem(
                displayName: "Photo \(index + 1)",
                format: .png
            )
        }
        let stagingGeneration = model.beginAttachmentStaging(stages)
        defer {
            model.endAttachmentStaging(generation: stagingGeneration)
            photoSelection = []
        }
        for (index, item) in selected.enumerated() {
            let stageID = stages[index].id
            guard !Task.isCancelled else { return }
            model.updateAttachmentStaging(
                id: stageID,
                state: .loading,
                progress: 0.05
            )
            do {
                guard let imported = try await ImportedPhotoLibraryFile.load(item) else {
                    failures += 1
                    model.failAttachmentStagingItem(id: stageID)
                    continue
                }
                defer { try? FileManager.default.removeItem(at: imported.url) }
                model.updateAttachmentStaging(
                    id: stageID,
                    displayName: imported.originalFileName,
                    state: .preparing,
                    progress: 0.4
                )
                try Task.checkCancellation()
                guard imported.kind == .image,
                      let prepared = await MobileImageAttachmentPreparer().prepare(url: imported.url) else {
                    failures += 1
                    model.failAttachmentStagingItem(id: stageID)
                    continue
                }
                try Task.checkCancellation()
                model.updateAttachmentStaging(id: stageID, progress: 0.85)
                let format: ChatOutboundAttachment.Format =
                    ["jpg", "jpeg"].contains(prepared.format.lowercased()) ? .jpeg : .png
                let stem = (imported.originalFileName as NSString).deletingPathExtension
                model.addAttachment(.init(
                    displayName: (stem.isEmpty ? "image" : stem) + (format == .jpeg ? ".jpeg" : ".png"),
                    data: prepared.data,
                    format: format,
                    thumbnailData: prepared.thumbnailData
                ))
                model.finishAttachmentStagingItem(id: stageID)
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                model.failAttachmentStagingItem(id: stageID)
            }
        }
        if failures > 0 {
            attachmentErrorMessage = failures == 1
                ? AgentChatStrings.imageCouldNotBePrepared
                : AgentChatStrings.someImagesCouldNotBePrepared
        }
    }

    private func stageFiles(_ urls: [URL]) async {
        let remaining = max(0, 10 - model.attachments.count)
        guard remaining > 0 else { return }
        attachmentErrorMessage = nil
        var failures = 0
        let selected = Array(urls.prefix(remaining))
        let stages = selected.map { url in
            AgentChatModeModel.AttachmentStagingItem(
                displayName: url.lastPathComponent.isEmpty ? AgentChatStrings.attachment : url.lastPathComponent,
                format: .file
            )
        }
        let stagingGeneration = model.beginAttachmentStaging(stages)
        defer { model.endAttachmentStaging(generation: stagingGeneration) }
        for (index, url) in selected.enumerated() {
            let stageID = stages[index].id
            guard !Task.isCancelled else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard let fileSize = values.fileSize,
                      fileSize <= 32 * 1024 * 1024 else {
                    failures += 1
                    model.failAttachmentStagingItem(id: stageID)
                    continue
                }
                model.updateAttachmentStaging(id: stageID, state: .loading)
                let data = try await readFile(url, byteCount: fileSize, stageID: stageID)
                try Task.checkCancellation()
                guard data.count <= 32 * 1024 * 1024 else {
                    failures += 1
                    model.failAttachmentStagingItem(id: stageID)
                    continue
                }
                let name = url.lastPathComponent.isEmpty ? "attachment" : url.lastPathComponent
                model.addAttachment(.init(
                    displayName: name,
                    data: data,
                    format: .file
                ))
                model.finishAttachmentStagingItem(id: stageID)
            } catch is CancellationError {
                return
            } catch {
                failures += 1
                model.failAttachmentStagingItem(id: stageID)
            }
        }
        if failures > 0 {
            attachmentErrorMessage = failures == 1
                ? AgentChatStrings.fileCouldNotBeAttached
                : AgentChatStrings.someFilesCouldNotBeAttached
        }
    }

    private func readFile(
        _ url: URL,
        byteCount: Int,
        stageID: UUID
    ) async throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(byteCount)
        var bytesRead = 0
        while bytesRead < byteCount {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(1024 * 1024, byteCount - bytesRead)) ?? Data()
            guard !chunk.isEmpty else { break }
            data.append(chunk)
            bytesRead += chunk.count
            model.updateAttachmentStaging(
                id: stageID,
                progress: byteCount == 0 ? 1 : Double(bytesRead) / Double(byteCount)
            )
            // Yield after each chunk so the cancel button remains responsive
            // even for a large local file.
            await Task.yield()
        }
        return data
    }

    private func toggleDictation() {
        dictation.toggle(existingText: model.draft) { merged in
            model.draft = merged
        }
    }

    private var dictationStatusText: String {
        switch dictation.state {
        case .requestingPermission:
            return AgentChatStrings.microphonePermissionGuidance
        case .listening:
            return AgentChatStrings.listening
        case .stopping:
            return AgentChatStrings.finishingDictation
        case .unavailable:
            return AgentChatStrings.dictationUnavailable
        case .idle:
            return ""
        }
    }

    private func openDictationSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct AgentAttachmentStagingRow: View {
    let item: AgentChatModeModel.AttachmentStagingItem

    private var stateLabel: String {
        switch item.state {
        case .queued: return AgentChatStrings.waiting
        case .loading: return AgentChatStrings.loading
        case .preparing: return AgentChatStrings.preparing
        case .completed: return AgentChatStrings.ready
        case .failed: return AgentChatStrings.couldNotAttach
        case .cancelled: return AgentChatStrings.cancelled
        }
    }

    private var iconName: String {
        switch item.state {
        case .queued, .loading, .preparing: return item.format == .file ? "doc" : "photo"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(item.state == .failed ? .red : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(stateLabel)
                    if item.state == .loading || item.state == .preparing {
                        Text(AgentChatStrings.attachmentProgress(Int(item.progress * 100)))
                            .monospacedDigit()
                    }
                }
                .font(.caption2)
                if item.state == .loading || item.state == .preparing {
                    ProgressView(value: item.progress)
                        .tint(.accentColor)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.displayName), \(stateLabel)")
        .accessibilityIdentifier("MobileAgentAttachmentStaging-\(item.id.uuidString)")
    }
}

private struct AgentChatAttachmentChip: View {
    let attachment: AgentChatModeModel.PendingAttachment
    let remove: () -> Void
    let preview: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: preview) {
                HStack(spacing: 6) {
                    if let image = UIImage(data: attachment.thumbnailData ?? attachment.data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 42, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: attachment.format == .file ? "doc" : "photo")
                            .frame(width: 42, height: 42)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text(attachment.displayName)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AgentChatStrings.previewAttachment(attachment.displayName))
            .accessibilityIdentifier("MobileAgentAttachmentPreview-\(attachment.id.uuidString)")
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AgentChatStrings.removeAttachment(attachment.displayName))
        }
        .padding(4)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AgentAttachmentPreview: View {
    let attachment: AgentChatModeModel.PendingAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var fileURL: URL?
    @State private var didAttemptFilePreview = false

    private var image: UIImage? {
        UIImage(data: attachment.thumbnailData ?? attachment.data)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                    }
                    .background(Color.black.opacity(0.06))
                } else if let fileURL {
                    MobileAttachmentQuickLookView(
                        fileURL: fileURL,
                        title: attachment.displayName,
                        accessibilityIdentifier: "MobileAgentAttachmentQuickLook"
                    )
                    .ignoresSafeArea(edges: .bottom)
                } else if attachment.format == .file && !didAttemptFilePreview {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(AgentChatStrings.preparingPreview)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text(attachment.displayName)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(attachment.data.count),
                            countStyle: .file
                        ))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        Text(AgentChatStrings.previewUnavailableForFileType)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(attachment.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AgentChatStrings.done) { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("MobileAgentAttachmentPreview")
        .task {
            guard attachment.format == .file, image == nil else { return }
            let safeName = (attachment.displayName as NSString).lastPathComponent
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-agent-preview-\(UUID().uuidString)-\(safeName)")
            do {
                try attachment.data.write(to: url, options: .atomic)
                fileURL = url
            } catch {
                // The metadata fallback remains available if Quick Look cannot
                // be given a temporary file.
            }
            didAttemptFilePreview = true
        }
        .onDisappear {
            if let fileURL {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
}

private extension ChatSessionDescriptor {
    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }
}
