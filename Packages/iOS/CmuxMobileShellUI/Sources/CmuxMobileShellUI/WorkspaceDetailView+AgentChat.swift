import CmuxAgentChat
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

#if os(iOS)
extension WorkspaceDetailView {
    var selectedTerminalID: String? {
        selectedTerminal?.id.rawValue
    }

    /// Chat sessions this view should render from right now. On first render
    /// after returning to a workspace, local `@State` is empty, but the shell
    /// store still has the last authoritative GUI-history snapshot for this
    /// workspace. Use that immediately so the toolbar does not flicker while the
    /// refresh task reconnects.
    private var visibleChatSessions: [ChatSessionDescriptor] {
        if chatSessionsWorkspaceID == workspace.id.rawValue {
            return chatSessions
        }
        return store.cachedChatSessions(workspaceID: workspace.id.rawValue)
    }

    /// The chat session belonging to the currently visible tab/terminal, if
    /// any. The toggle and the chat bind to THIS: the tab the user is looking
    /// at. A tab with no agent session yields nil; a past agent that has since
    /// ended still matches here because its record keeps the terminal binding.
    private var sessionForSelectedTerminal: ChatSessionDescriptor? {
        guard let terminalID = selectedTerminalID else { return nil }
        return visibleChatSessions.first { $0.terminalID == terminalID }
    }

    /// The session backing the toolbar toggle. Prefer the currently selected
    /// terminal's live match, but fall back to the last cached match while the
    /// selected terminal is temporarily unavailable during mode transitions.
    private var chatToggleSession: ChatSessionDescriptor? {
        if let sessionForSelectedTerminal {
            return sessionForSelectedTerminal
        }
        guard let terminalID = cachedChatToggleTerminalID else { return nil }
        if let selectedTerminalID, selectedTerminalID != terminalID {
            return nil
        }
        return visibleChatSessions.first { $0.terminalID == terminalID }
    }

    var shouldShowChatToggle: Bool {
        isChatMode || chatToggleSession != nil
    }

    /// The session chat mode opens: the visible tab's session, or the pinned
    /// session while chat mode is on.
    var chosenChatSession: ChatSessionDescriptor? {
        if let pinnedChatSessionID {
            return visibleChatSessions.first { $0.id == pinnedChatSessionID }
        }
        return chatToggleSession
    }

    /// The session whose full chat model should stay warm while this detail is
    /// visible. In terminal mode this is the selected terminal's session; in
    /// chat mode it is the pinned session.
    private var warmChatSession: ChatSessionDescriptor? {
        chosenChatSession ?? chatToggleSession
    }

    /// Identity for the session refetch: workspace, installed chat source, and a
    /// foreground epoch. A change re-runs `.task(id:)`, which re-subscribes to
    /// the push stream and re-pulls the authoritative session list.
    var chatRefreshKey: String {
        let connected = store.connectionState == .connected ? 1 : 0
        let foreground = scenePhase == .background ? 0 : 1
        return "\(workspace.id.rawValue)#\(store.agentChatEventSourceIdentity)#\(connected)#\(foreground)"
    }

    /// Identity for the selected chat model's event stream. Descriptor updates
    /// reconcile through `applyDescriptorSnapshot`, so list refreshes do not
    /// restart the same long-lived subscription.
    var chatConversationWarmKey: String {
        let connected = store.connectionState == .connected ? 1 : 0
        let foreground = scenePhase == .background ? 0 : 1
        guard let session = warmChatSession else {
            return "\(workspace.id.rawValue)#none#\(store.agentChatEventSourceIdentity)#\(connected)#\(foreground)"
        }
        return "\(workspace.id.rawValue)#\(session.id)#\(store.agentChatEventSourceIdentity)#\(connected)#\(foreground)"
    }

    @ViewBuilder
    func chatContent(_ session: ChatSessionDescriptor) -> some View {
        if let conversation = chatConversationStores[session.id] {
            WorkspaceChatPane(
                session: session,
                conversation: conversation,
                store: store,
                workspaceName: workspace.name,
                tabName: tabName(for: session),
                draft: Binding(
                    get: { chatDrafts[session.id] ?? "" },
                    set: { chatDrafts[session.id] = $0 }
                ),
                backButtonConfiguration: backButtonConfiguration,
                titleMenuContent: { titleMenuContent },
                onExitChat: {
                    withAnimation(.snappy(duration: 0.28)) {
                        isChatMode = false
                    }
                    pinnedChatSessionID = nil
                }
            )
            .id(session.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mobileChatTopScrollEdgeLayout(legacyTopPadding: terminalTopPadding)
            .mobileTerminalNavigationChrome()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    toolbarTrailingCluster
                }
            }
            .task(id: chatRefreshKey) { await refreshChatSessions() }
            .closeWorkspaceConfirmation(
                isPresented: $isConfirmingClose,
                confirm: confirmCloseWorkspaceFromMenu
            )
            .workspaceRenameDialog(
                isPresented: $isRenamePresented,
                text: $renameText,
                onSave: commitRenameFromDialog
            )
        } else {
            Color.clear
                .task(id: session.id) {
                    _ = ensureChatConversationStore(for: session)
                }
        }
    }

    @ViewBuilder
    var toolbarTrailingCluster: some View {
        HStack(spacing: 8) {
            if shouldShowChatToggle {
                chatToggleButton
                    .frame(width: 44, height: 44)
                    .transition(.scale(scale: 0.82, anchor: .trailing).combined(with: .opacity))
            }
            terminalPickerToolbarButton
                .frame(width: 44, height: 44)
        }
        .frame(width: shouldShowChatToggle ? 96 : 44, height: 44, alignment: .trailing)
        .animation(.snappy(duration: 0.25), value: shouldShowChatToggle)
    }

    var chatToggleButton: some View {
        Button(action: toggleChatMode) {
            Image(systemName: isChatMode
                ? "bubble.left.and.bubble.right.fill"
                : "bubble.left.and.bubble.right")
        }
        .accessibilityLabel(L10n.string("mobile.workspace.agentChat", defaultValue: "Agent Chat"))
        .accessibilityIdentifier("MobileWorkspaceAgentChatButton")
        .disabled(!isChatMode && chatToggleSession == nil)
    }

    /// Keeps the chat-capable session list current while this workspace is
    /// shown, so the GUI toggle appears as soon as a coding agent becomes
    /// active, without polling. The Mac pushes a `chat.message` frame on every
    /// descriptor/state change; we register the push stream first, seed the list
    /// once, then fold each subsequent frame in.
    func refreshChatSessions() async {
        let workspaceID = workspace.id.rawValue
        let sourceIdentity = store.agentChatEventSourceIdentity
        guard let source = store.makeChatEventSource() else {
            applyChatModeFallback(canInvalidateSelection: false)
            return
        }
        var reducer = ChatSessionListReducer(workspaceID: workspaceID)
        let stream = await source.sessionEvents()
        let seedOutcome: WorkspaceChatSessionRefreshOutcome
        do {
            seedOutcome = .authoritative(try await source.sessions(workspaceID: workspaceID))
        } catch {
            seedOutcome = store.chatSessionListFailureMeansUnsupported(error)
                ? .authoritative([])
                : .unavailable
        }
        guard !Task.isCancelled,
              workspaceID == workspace.id.rawValue,
              sourceIdentity == store.agentChatEventSourceIdentity
        else { return }
        let nextSessions = seedOutcome.applying(to: visibleChatSessions)
        withAnimation(.snappy(duration: 0.25)) {
            chatSessionsWorkspaceID = workspaceID
            chatSessions = nextSessions
        }
        if seedOutcome.canInvalidateSelection {
            store.rememberChatSessions(nextSessions, workspaceID: workspaceID)
        }
        reconcileChatSessionSnapshot(seedOutcomeCanInvalidateSelection: seedOutcome.canInvalidateSelection)
        for await frame in stream {
            guard !Task.isCancelled,
                  workspaceID == workspace.id.rawValue,
                  sourceIdentity == store.agentChatEventSourceIdentity
            else { break }
            let current = visibleChatSessions
            let next = reducer.applying(frame, to: current)
            guard next != current else { continue }
            withAnimation(.snappy(duration: 0.25)) {
                chatSessionsWorkspaceID = workspaceID
                chatSessions = next
            }
            store.rememberChatSessions(next, workspaceID: workspaceID)
            reconcileChatSessionSnapshot(seedOutcomeCanInvalidateSelection: true)
        }
    }

    /// Runs the selected terminal's chat store while terminal mode is visible.
    /// Opening chat reuses the same store, so there is only one subscription and
    /// the transcript/history loaded in the background remains available.
    func runWarmChatConversation() async {
        guard scenePhase != .background,
              let session = warmChatSession,
              let conversation = ensureChatConversationStore(for: session, requiresCurrentSource: true)
        else { return }
        pruneCachedChatConversations()
        await conversation.run()
    }

    /// Keeps the toolbar's chat affordance anchored to the latest session
    /// snapshot for the selected terminal. Authoritative empty snapshots clear
    /// the anchor; unavailable refreshes preserve `chatSessions`, so the anchor
    /// naturally survives reconnects.
    func refreshCachedChatToggleAnchor() {
        if let terminalID = sessionForSelectedTerminal?.terminalID {
            cachedChatToggleTerminalID = terminalID
            return
        }

        if let selectedTerminalID {
            cachedChatToggleTerminalID = nil
            return
        }

        guard let terminalID = cachedChatToggleTerminalID else { return }
        if !visibleChatSessions.contains(where: { $0.terminalID == terminalID }) {
            cachedChatToggleTerminalID = nil
        }
    }

    /// Creates or updates the cached conversation store for a session. This is
    /// called from tasks/actions, not from `body`, so the body remains a pure
    /// projection of state.
    @discardableResult
    private func ensureChatConversationStore(
        for session: ChatSessionDescriptor,
        requiresCurrentSource: Bool = false
    ) -> ChatConversationStore? {
        let source = store.makeChatEventSource()
        if let existing = chatConversationStores[session.id] {
            if let source {
                existing.replaceSource(
                    source,
                    descriptor: session,
                    sourceIdentity: store.agentChatEventSourceIdentity
                )
            } else if requiresCurrentSource {
                return nil
            }
            return existing
        }
        guard let source else { return nil }
        let conversation = ChatConversationStore(
            descriptor: session,
            source: source,
            sourceIdentity: store.agentChatEventSourceIdentity
        )
        chatConversationStores[session.id] = conversation
        return conversation
    }

    /// Flip between the terminal and the inline agent chat, pinning/unpinning the
    /// chosen session. Shared by the toolbar button and the menu row.
    private func toggleChatMode() {
        if isChatMode {
            withAnimation(.snappy(duration: 0.28)) { isChatMode = false }
            pinnedChatSessionID = nil
            return
        }
        guard let openingSession = chatToggleSession,
              ensureChatConversationStore(for: openingSession) != nil else { return }
        withAnimation(.snappy(duration: 0.28)) {
            isChatMode = true
        }
        pinnedChatSessionID = openingSession.id
    }

    /// Keeps the active transcript store warm without retaining stores for every
    /// ended session the host keeps in history. During transport loss the warm
    /// session is still derived from the preserved session list, so reconnects do
    /// not evict the GUI state the user can currently open.
    private func pruneCachedChatConversations() {
        guard let warmID = warmChatSession?.id else {
            chatConversationStores.removeAll()
            return
        }
        chatConversationStores = chatConversationStores.filter { $0.key == warmID }
    }

    /// While chat is open and pinned to a session that has ended, if the agent
    /// was reopened on the same terminal, re-pin to the newer non-ended session
    /// so the GUI becomes editable again.
    private func repinToReopenedSession() {
        guard isChatMode,
              let pinnedID = pinnedChatSessionID,
              let pinned = visibleChatSessions.first(where: { $0.id == pinnedID }),
              pinned.state == .ended,
              let terminalID = pinned.terminalID else { return }
        let live = visibleChatSessions
            .filter { $0.terminalID == terminalID && $0.id != pinnedID && $0.state != .ended }
            .max { ($0.lastActivityAt ?? .distantPast) < ($1.lastActivityAt ?? .distantPast) }
        if let live {
            pinnedChatSessionID = live.id
        }
    }

    /// If the session backing chat mode disappeared, fall back to the terminal
    /// rather than showing an empty chat.
    private func applyChatModeFallback(canInvalidateSelection: Bool) {
        guard canInvalidateSelection else { return }
        if isChatMode, chosenChatSession == nil {
            isChatMode = false
            pinnedChatSessionID = nil
        }
    }

    private func reconcileChatSessionSnapshot(seedOutcomeCanInvalidateSelection: Bool) {
        refreshCachedChatToggleAnchor()
        pruneCachedChatConversations()
        if let warmChatSession {
            _ = ensureChatConversationStore(for: warmChatSession)
        }
        repinToReopenedSession()
        applyChatModeFallback(canInvalidateSelection: seedOutcomeCanInvalidateSelection)
    }

}
#endif
