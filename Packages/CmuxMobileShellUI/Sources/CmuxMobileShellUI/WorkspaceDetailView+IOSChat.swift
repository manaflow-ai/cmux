import CmuxAgentChat
import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

#if os(iOS)
extension WorkspaceDetailView {
    /// The chat session belonging to the currently visible tab/terminal, if
    /// any. The toggle and the chat bind to this tab, so a tab's chat never
    /// shows another tab's history, and a tab with no agent session yields nil.
    var sessionForSelectedTerminal: ChatSessionDescriptor? {
        guard let terminalID = selectedTerminal?.id.rawValue else { return nil }
        return availableChatSessions.first { $0.terminalID == terminalID }
    }

    /// The session chat mode opens: the visible tab's session, or the pinned
    /// session while chat mode is on.
    var chosenChatSession: ChatSessionDescriptor? {
        if let pinnedChatSessionID {
            return pinnedChatSessionCandidates.first { $0.id == pinnedChatSessionID }
        }
        return sessionForSelectedTerminal
    }

    /// Session descriptors currently usable for toolbar availability. The
    /// workspace-list seed is only a first-paint fallback; the live chat session
    /// list becomes authoritative after its first successful fetch.
    var availableChatSessions: [ChatSessionDescriptor] {
        let liveSessionsAreCurrent = hasLoadedLiveChatSessions && chatSessionsWorkspaceID == workspace.id
        let currentChatSessions = chatSessionsWorkspaceID == workspace.id ? chatSessions : []
        return liveSessionsAreCurrent
            ? ChatSessionDescriptor.openableByTerminal(currentChatSessions)
            : Self.mergedChatSessions(
                primary: currentChatSessions,
                fallback: store.seededChatSessions(workspaceID: workspace.id.rawValue)
            )
    }

    var pinnedChatSessionCandidates: [ChatSessionDescriptor] {
        let currentChatSessions = chatSessionsWorkspaceID == workspace.id ? chatSessions : []
        let seeded = store.seededChatSessions(workspaceID: workspace.id.rawValue)
        guard !seeded.isEmpty else { return currentChatSessions }
        var seen = Set(currentChatSessions.map(\.id))
        return currentChatSessions + seeded.filter { seen.insert($0.id).inserted }
    }

    /// The tab/terminal name for a session, for the chat header subtitle.
    func tabName(for session: ChatSessionDescriptor) -> String? {
        workspace.terminals.first { $0.id.rawValue == session.terminalID }?.name
    }

    /// Agent chat rendered in place of the terminal while chat mode is on.
    /// Carries the same toolbar so the toggle flips back.
    @ViewBuilder
    func chatContent(_ session: ChatSessionDescriptor) -> some View {
        WorkspaceChatPane(
            session: session,
            store: store,
            workspaceName: workspace.name,
            tabName: tabName(for: session),
            draft: Binding(
                get: { chatDrafts[session.id] ?? "" },
                set: { chatDrafts[session.id] = $0 }
            ),
            onExitChat: {
                withAnimation(.snappy(duration: 0.28)) {
                    isChatMode = false
                }
                pinnedChatSessionID = nil
            }
        )
        .id(session.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .mobileTerminalNavigationChrome()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                chatToggleButton
                newWorkspaceToolbarButton
                terminalPickerToolbarButton
            }
        }
        .task(id: chatRefreshKey) { await refreshChatSessions() }
    }

    /// Toolbar toggle between terminal and chat. Shown only when the currently
    /// visible tab has an agent session, or while chat is already on.
    @ViewBuilder
    var chatToggleButton: some View {
        if isChatMode || sessionForSelectedTerminal != nil {
            Button {
                withAnimation(.snappy(duration: 0.28)) {
                    isChatMode.toggle()
                }
                pinnedChatSessionID = isChatMode ? chosenChatSession?.id : nil
            } label: {
                Image(systemName: isChatMode
                    ? "bubble.left.and.bubble.right.fill"
                    : "bubble.left.and.bubble.right")
            }
            .accessibilityLabel(chatToggleAccessibilityLabel)
            .accessibilityValue(chatToggleAccessibilityValue)
            .accessibilityIdentifier("MobileWorkspaceAgentChatButton")
            .disabled(!isChatMode && chosenChatSession == nil)
        }
    }

    var chatToggleAccessibilityLabel: String {
        if isChatMode {
            return L10n.string("mobile.workspace.agentChat.showTerminal", defaultValue: "Show Terminal")
        }
        return L10n.string("mobile.workspace.agentChat.showChat", defaultValue: "Show Agent Chat")
    }

    var chatToggleAccessibilityValue: String {
        if isChatMode {
            return L10n.string("mobile.workspace.agentChat.chatOpen", defaultValue: "Chat open")
        }
        return L10n.string("mobile.workspace.agentChat.terminalOpen", defaultValue: "Terminal open")
    }

    /// Identity for the session refetch: workspace plus connection epoch.
    var chatRefreshKey: String {
        "\(workspace.id.rawValue)#\(store.connectionState == .connected ? 1 : 0)"
    }

    /// Keeps the chat-capable session list current while this workspace is
    /// shown, so the GUI toggle appears as soon as a coding agent becomes
    /// active, without polling.
    func refreshChatSessions() async {
        prepareChatSessionsForCurrentWorkspace()
        guard let source = store.makeChatEventSource() else {
            chatSessions = []
            hasLoadedLiveChatSessions = false
            applyChatModeFallback()
            return
        }
        let reducer = ChatSessionListReducer(workspaceID: workspace.id.rawValue)
        let stream = await source.sessionEvents()
        do {
            let seeded = try await source.sessions(workspaceID: workspace.id.rawValue)
            withAnimation(.snappy(duration: 0.25)) {
                chatSessions = seeded
                hasLoadedLiveChatSessions = true
            }
        } catch {
            // The workspace-list seed is read directly from the store by
            // `availableChatSessions`; do not keep old live/session state as a
            // primary source when the authoritative fetch fails.
            withAnimation(.snappy(duration: 0.25)) { chatSessions = [] }
            hasLoadedLiveChatSessions = false
        }
        applyChatModeFallback()
        for await frame in stream {
            let baseline = Self.streamReducerBaseline(
                current: chatSessions,
                hasLoadedLiveSessions: hasLoadedLiveChatSessions,
                seeded: store.seededChatSessions(workspaceID: workspace.id.rawValue)
            )
            guard Self.frameUpdatesSessionList(
                frame,
                workspaceID: workspace.id.rawValue,
                baseline: baseline
            ) else { continue }
            let next = reducer.applying(frame, to: baseline)
            withAnimation(.snappy(duration: 0.25)) {
                chatSessions = next
                hasLoadedLiveChatSessions = true
            }
            applyChatModeFallback()
        }
    }

    func prepareChatSessionsForCurrentWorkspace() {
        guard chatSessionsWorkspaceID != workspace.id else { return }
        chatSessionsWorkspaceID = workspace.id
        chatSessions = []
        hasLoadedLiveChatSessions = false
        pinnedChatSessionID = nil
        isChatMode = false
    }

    static func mergedChatSessions(
        primary: [ChatSessionDescriptor],
        fallback: [ChatSessionDescriptor]
    ) -> [ChatSessionDescriptor] {
        guard !fallback.isEmpty else { return primary }
        var seen = Set(primary.map(\.id))
        var merged = primary
        for session in fallback where seen.insert(session.id).inserted {
            merged.append(session)
        }
        return ChatSessionDescriptor.openableByTerminal(merged)
    }

    static func streamReducerBaseline(
        current: [ChatSessionDescriptor],
        hasLoadedLiveSessions: Bool,
        seeded: [ChatSessionDescriptor]
    ) -> [ChatSessionDescriptor] {
        hasLoadedLiveSessions
            ? current
            : mergedChatSessions(primary: current, fallback: seeded)
    }

    static func frameUpdatesSessionList(
        _ frame: ChatSessionEventFrame,
        workspaceID: String,
        baseline: [ChatSessionDescriptor]
    ) -> Bool {
        switch frame.event {
        case .descriptorChanged(let descriptor):
            return descriptor.workspaceID == workspaceID
        case .stateChanged:
            return baseline.contains { $0.id == frame.sessionID }
        case .appended, .updated, .terminalBlocks, .reset, .unknown:
            return false
        }
    }

    /// If the session backing chat mode disappeared, fall back to the terminal
    /// rather than showing an empty chat.
    func applyChatModeFallback() {
        if isChatMode, chosenChatSession == nil {
            isChatMode = false
            pinnedChatSessionID = nil
        }
    }

    /// The browser pane shown when this workspace has an active browser surface.
    /// It carries its own navigation chrome, so it does not inherit terminal
    /// keyboard or safe-area handling.
    @ViewBuilder
    func browserContent(_ browser: BrowserSurfaceState) -> some View {
        MobileBrowserPane(
            state: browser,
            onClose: { browserStore.closeBrowser(for: workspace.id.rawValue) }
        )
        .id(browser.id.rawValue)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(browser.title ?? workspace.name)
        .mobileTerminalNavigationChrome()
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                chatToggleButton
                newWorkspaceToolbarButton
                terminalPickerToolbarButton
            }
        }
        .task(id: chatRefreshKey) { await refreshChatSessions() }
    }
}
#endif
