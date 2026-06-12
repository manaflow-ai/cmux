#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Toolbar affordance for the workspace's agent chat: visible when the
/// connected Mac reports chat-capable agent sessions in this workspace.
/// One live session opens directly; several present a picker so a dead
/// session can never shadow a live one (the "Session ended while the
/// agent was running" report). Needs-input sessions sort first.
struct WorkspaceAgentChatButton: View {
    let workspace: MobileWorkspacePreview
    let store: CMUXMobileShellStore

    @State private var sessions: [ChatSessionDescriptor] = []
    @State private var presentation: Presentation?
    /// Per-session composer drafts, surviving cover dismissal while the
    /// workspace view lives (a closed chat reopened mid-thought keeps the
    /// half-typed prompt).
    @State private var drafts: [String: String] = [:]

    var body: some View {
        // The empty state still renders a zero-sized view (not EmptyView):
        // `.task` never fires on a modifier chain whose content resolves to
        // EmptyView, and the session fetch below must run even while the
        // button is hidden.
        ZStack {
            if openableSessions.count > 1 {
                Menu {
                    ForEach(openableSessions, id: \.id) { session in
                        Button {
                            open(session)
                        } label: {
                            Label(sessionMenuTitle(session), systemImage: sessionMenuSymbol(session))
                        }
                    }
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .accessibilityLabel(L10n.string("mobile.workspace.agentChat", defaultValue: "Agent Chat"))
                .accessibilityIdentifier("MobileWorkspaceAgentChatButton")
            } else if let session = openableSessions.first {
                Button {
                    open(session)
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .accessibilityLabel(L10n.string("mobile.workspace.agentChat", defaultValue: "Agent Chat"))
                .accessibilityIdentifier("MobileWorkspaceAgentChatButton")
            } else {
                Color.clear
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
        // Refetches per workspace and per reconnect; a session that starts
        // while this workspace stays open appears after renavigation or
        // reconnection (deliberate staleness, no polling).
        .task(id: RefreshKey(workspaceID: workspace.id.rawValue, isConnected: store.connectionState == .connected)) {
            sessions = await store.chatSessions(workspaceID: workspace.id.rawValue)
        }
        .fullScreenCover(item: $presentation, onDismiss: {
            // Session states moved while the cover was up (the agent ended,
            // another started); refresh so the next open picks correctly.
            Task { sessions = await store.chatSessions(workspaceID: workspace.id.rawValue) }
        }) { presentation in
            NavigationStack {
                ChatScreen(
                    store: presentation.conversation,
                    draft: Binding(
                        get: { drafts[presentation.id] ?? "" },
                        set: { drafts[presentation.id] = $0 }
                    ),
                    onOpenTerminal: { openTerminal(presentation.conversation.descriptor) }
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("mobile.common.done", defaultValue: "Done")) {
                            self.presentation = nil
                        }
                        .accessibilityIdentifier("MobileWorkspaceAgentChatDone")
                    }
                }
            }
        }
    }

    /// The escape hatch: land on the session's actual terminal surface,
    /// not just back on the workspace.
    private func openTerminal(_ descriptor: ChatSessionDescriptor) {
        if let terminalID = descriptor.terminalID {
            store.selectedTerminalID = MobileTerminalPreview.ID(rawValue: terminalID)
        }
        presentation = nil
    }

    /// Sessions worth opening, attention first: needs-input, then
    /// working, then idle (each by recency). Ended sessions are offered
    /// only when nothing is alive — a dead session must never shadow a
    /// live one.
    private var openableSessions: [ChatSessionDescriptor] {
        ChatSessionDescriptor.openable(sessions)
    }

    private func sessionMenuTitle(_ session: ChatSessionDescriptor) -> String {
        session.title ?? session.agentKind.displayName
    }

    private func sessionMenuSymbol(_ session: ChatSessionDescriptor) -> String {
        switch session.state {
        case .needsInput: return "exclamationmark.bubble"
        case .working: return "circle.dotted.circle"
        case .idle: return "bubble"
        case .ended: return "moon.zzz"
        }
    }

    private func open(_ session: ChatSessionDescriptor) {
        guard let source = store.makeChatEventSource() else { return }
        presentation = Presentation(
            id: session.id,
            conversation: ChatConversationStore(descriptor: session, source: source)
        )
    }

    /// Presentation payload keeping the conversation store's identity
    /// stable for the cover's lifetime.
    private struct Presentation: Identifiable {
        let id: String
        let conversation: ChatConversationStore
    }

    /// Task identity for the session fetch: workspace plus connection
    /// epoch, so a reconnect refetches.
    private struct RefreshKey: Equatable {
        let workspaceID: String
        let isConnected: Bool
    }
}
#endif
