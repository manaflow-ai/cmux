import CmuxAgentChat
import CmuxDiffUI
import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

#if os(iOS)
extension WorkspaceDetailView {
    var workspaceDiffEntryGate: WorkspaceDiffEntryGate {
        WorkspaceDiffEntryGate(
            supportsWorkspaceDiffs: store.supportsWorkspaceDiffs,
            isConnected: store.connectionState == .connected
        )
    }

    var showsDebugDiffEntryPoints: Bool {
        #if DEBUG
        displaySettings.showDiffEntryPoints && workspaceDiffEntryGate.canPresent
        #else
        false
        #endif
    }

    @MainActor func presentWorkspaceDiff() {
        guard workspaceDiffEntryGate.canPresent else { return }
        isWorkspaceDiffPresented = true
    }

    @ViewBuilder
    var workspaceDiffPresentation: some View {
        if let service = store.makeDiffsService() {
            DiffLiveScreen(
                store: DiffScreenStore(
                    service: service,
                    workspaceRef: workspace.id.rawValue,
                    viewedStore: DiffViewedStore(defaults: .standard),
                    layoutPreferenceStore: DiffLayoutPreferenceStore(defaults: .standard)
                ),
                navigationModel: displaySettings.diffNavigationModel,
                quickNoteActions: workspaceDiffQuickNoteActions,
                dismissViewer: { isWorkspaceDiffPresented = false }
            )
        } else {
            ContentUnavailableView(
                workspaceChangesUnavailableTitle,
                systemImage: "wifi.slash",
                description: Text(workspaceChangesUnavailableMessage)
            )
        }
    }

    var workspaceDiffQuickNoteActions: DiffQuickNoteActions {
        DiffQuickNoteActions(
            isAvailable: diffAgentSession != nil,
            send: { prompt in await sendDiffPrompt(prompt) },
            editInComposer: { prompt in editDiffPrompt(prompt) }
        )
    }

    private var diffAgentSession: ChatSessionDescriptor? {
        let openable = ChatSessionDescriptor.openable(
            visibleChatSessions.filter { $0.kind == .agent }
        )
        if let chosenChatSession,
           openable.contains(where: { $0.id == chosenChatSession.id }) {
            return chosenChatSession
        }
        return openable.first
    }

    @MainActor private func sendDiffPrompt(_ prompt: String) async {
        guard let session = diffAgentSession,
              let conversation = ensureChatConversationStore(for: session)
        else { return }
        await conversation.send(text: prompt, attachments: [])
    }

    @MainActor private func editDiffPrompt(_ prompt: String) {
        guard let session = diffAgentSession,
              ensureChatConversationStore(for: session) != nil
        else { return }
        chatDrafts[session.id] = prompt
        pinnedChatSessionID = session.id
        withAnimation(.snappy(duration: 0.28)) {
            isChatMode = true
            isWorkspaceDiffPresented = false
        }
    }

    var workspaceChangesLabel: String {
        L10n.string("mobile.workspace.changes", defaultValue: "Changes")
    }

    private var workspaceChangesUnavailableTitle: String {
        L10n.string("mobile.workspace.changesUnavailable.title", defaultValue: "Changes unavailable")
    }

    private var workspaceChangesUnavailableMessage: String {
        L10n.string(
            "mobile.workspace.changesUnavailable.message",
            defaultValue: "Reconnect to a compatible Mac to view workspace changes."
        )
    }
}
#endif
