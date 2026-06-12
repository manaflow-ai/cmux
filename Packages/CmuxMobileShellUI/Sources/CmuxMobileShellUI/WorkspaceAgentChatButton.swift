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
        Group {
            if let session = sessions.first {
                Button {
                    open(session)
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
                .accessibilityLabel(L10n.string("mobile.workspace.agentChat", defaultValue: "Agent Chat"))
                .accessibilityIdentifier("MobileWorkspaceAgentChatButton")
            }
        }
        .task(id: workspace.id) {
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
}
#endif
