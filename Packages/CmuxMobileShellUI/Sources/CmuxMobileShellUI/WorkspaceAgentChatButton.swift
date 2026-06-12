#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Toolbar affordance for the workspace's agent chat: visible when the
/// connected Mac reports chat-capable agent sessions in this workspace,
/// opening the most recently active one as a full-screen conversation.
struct WorkspaceAgentChatButton: View {
    let workspace: MobileWorkspacePreview
    let store: CMUXMobileShellStore

    @State private var sessions: [ChatSessionDescriptor] = []
    @State private var presentation: Presentation?

    var body: some View {
        // The empty state still renders a zero-sized view (not EmptyView):
        // `.task` never fires on a modifier chain whose content resolves to
        // EmptyView, and the session fetch below must run even while the
        // button is hidden.
        ZStack {
            if let session = sessions.first {
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
        .fullScreenCover(item: $presentation) { presentation in
            NavigationStack {
                ChatScreen(
                    store: presentation.conversation,
                    onOpenTerminal: { self.presentation = nil }
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
