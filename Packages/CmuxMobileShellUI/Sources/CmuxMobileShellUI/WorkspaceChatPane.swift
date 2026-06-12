#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// The agent chat rendered inline in the workspace detail, in place of the
/// terminal, when chat mode is toggled on. There is no cover and no Done
/// button: the same toolbar toggle flips back to the terminal.
struct WorkspaceChatPane: View {
    let session: ChatSessionDescriptor
    let store: CMUXMobileShellStore
    /// Composer draft, owned by the parent so it survives toggling back to
    /// the terminal and returning mid-thought.
    @Binding var draft: String
    /// Flips chat mode off (the toggle's "back to terminal" path).
    let onExitChat: () -> Void

    @State private var conversation: ChatConversationStore?

    var body: some View {
        Group {
            if let conversation {
                ChatScreen(
                    store: conversation,
                    draft: $draft,
                    providesOwnChrome: false,
                    onOpenTerminal: openTerminal
                )
                // The host (workspace detail) owns the nav bar, so the
                // live session-state header is supplied here as a principal
                // item rather than by ChatScreen, which would be dropped
                // under the workspace's own chrome.
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ChatSessionHeaderView(
                            descriptor: conversation.descriptor,
                            agentState: conversation.agentState,
                            isConnected: conversation.isConnected
                        )
                    }
                }
            } else {
                Color.clear
            }
        }
        // Rebuild the conversation store when the bound session changes
        // (toggling into a different live session), tearing down the old
        // event subscription.
        .task(id: session.id) {
            if conversation?.descriptor.id != session.id {
                conversation = store.makeChatEventSource().map {
                    ChatConversationStore(descriptor: session, source: $0)
                }
            }
        }
    }

    /// The escape hatch: select the session's terminal surface, then leave
    /// chat mode so the terminal shows.
    private func openTerminal() {
        if let terminalID = session.terminalID {
            store.selectedTerminalID = MobileTerminalPreview.ID(rawValue: terminalID)
        }
        onExitChat()
    }
}
#endif
