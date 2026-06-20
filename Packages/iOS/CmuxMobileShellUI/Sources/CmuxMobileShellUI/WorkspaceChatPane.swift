#if os(iOS)
import CmuxAgentChat
import CmuxAgentChatUI
import CmuxMobileBrowser
import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

/// The agent chat rendered inline in the workspace detail, in place of the
/// terminal, when chat mode is toggled on. There is no cover and no Done
/// button: the same toolbar toggle flips back to the terminal.
struct WorkspaceChatPane: View {
    let session: ChatSessionDescriptor
    let store: CMUXMobileShellStore
    /// The owning workspace's name, shown as the header title (so the header
    /// reads as the workspace, not the session's first prompt).
    let workspaceName: String
    /// The name of the tab/terminal this session lives on, shown as the
    /// header subtitle.
    let tabName: String?
    /// Composer draft, owned by the parent so it survives toggling back to
    /// the terminal and returning mid-thought.
    @Binding var draft: String
    /// Flips chat mode off (the toggle's "back to terminal" path).
    let onExitChat: () -> Void

    @Environment(BrowserSurfaceStore.self) private var browserStore

    @State private var conversation: ChatConversationStore?
    /// Full content width, used to bound the toolbar-principal header so a long
    /// workspace name truncates in the center instead of overflowing under the
    /// back button / trailing toolbar buttons.
    @State private var contentWidth: CGFloat = 0

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
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ChatSessionHeaderView(
                            descriptor: conversation.descriptor,
                            agentState: conversation.agentState,
                            isConnected: conversation.isConnected,
                            titleOverride: workspaceName,
                            subtitle: tabName
                        )
                        // Centered principal item: cap it to the clear center gap
                        // so a long workspace name truncates instead of
                        // underlapping the toolbar. The chat view always shows the
                        // chat toggle in its trailing cluster. Reserve only the
                        // real side clusters so the middle grows as much as it can.
                        .frame(maxWidth: MobileNavTitleWidth.cap(
                            contentWidth: contentWidth,
                            hasChatToggle: true
                        ))
                        // The header bar is cleared on iOS 26 so the transcript
                        // shows through it; back the header on its own Liquid
                        // Glass pill so it stays readable over the messages.
                        .mobileGlassNavigationTitle()
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
            // Leaving chat for the terminal is a chrome action, not a typing
            // intent, so suppress the target's autofocus (matches the terminal
            // picker). Using selectTerminalFromChrome instead of setting
            // selectedTerminalID directly avoids a surprise keyboard pop.
            store.selectTerminalFromChrome(MobileTerminalPreview.ID(rawValue: terminalID))
        }
        // Close any active browser pane for this workspace first: the detail
        // body prefers browser over terminal, so leaving a browser open would
        // make "Open Terminal" land back on the browser instead of the
        // terminal the user asked for (matches the terminal-picker path).
        if let workspaceID = session.workspaceID {
            browserStore.closeBrowser(for: workspaceID)
        }
        onExitChat()
    }
}
#endif
