#if os(iOS)
import CmuxMobileShell
import SwiftUI

extension WorkspaceDetailView {
    var workspaceChangesChip: MobileWorkspaceChangesChip? {
        store.workspaceChangeChipsByWorkspaceID[workspace.rpcWorkspaceID.rawValue]
    }

    /// Matches detail chrome's workspace-scoped connected state and the host capability gate.
    var workspaceChangesAreAvailable: Bool {
        store.workspaceChangesCapable && connectionStatus == .connected
    }

    /// Dirty terminal-title entry point. Chat and browser headers keep their
    /// existing labels and chrome unchanged.
    var workspaceTitleChangesChip: MobileWorkspaceChangesChip? {
        let showsChatHeader = isChatMode
            && chosenChatSession.map { chatConversationStores[$0.id] != nil } == true
        guard !showsChatHeader,
              activeBrowser == nil,
              workspaceChangesAreAvailable,
              let chip = workspaceChangesChip,
              chip.filesChanged > 0 else { return nil }
        return chip
    }

    /// Restarts hint eligibility only when its authoritative inputs change.
    var workspaceChangesHintEligibilityKey: String {
        let capability = store.workspaceChangesCapable ? 1 : 0
        let connected = connectionStatus == .connected ? 1 : 0
        let filesChanged = workspaceChangesChip?.filesChanged ?? 0
        return "\(workspace.rpcWorkspaceID.rawValue)#\(capability)#\(connected)#\(filesChanged)"
    }

    /// The single presentation path shared by the toolbar, title pill, and hint banner.
    func openWorkspaceChanges() {
        guard workspaceChangesAreAvailable else { return }
        let workspaceID = workspace.rpcWorkspaceID.rawValue
        dismissTerminalKeyboardForChrome()
        store.dismissWorkspaceChangesHint(workspaceID: workspaceID)
        workspaceChangesHint = nil
        isWorkspaceChangesSheetPresented = true
        Task {
            await store.fetchWorkspaceChangesSummaries(
                workspaceIDs: [workspaceID],
                force: true
            )
        }
    }

    func dismissWorkspaceChangesHint() {
        let workspaceID = workspace.rpcWorkspaceID.rawValue
        store.dismissWorkspaceChangesHint(workspaceID: workspaceID)
        workspaceChangesHint = nil
    }

    func refreshWorkspaceChangesHint() {
        guard workspaceChangesAreAvailable else {
            workspaceChangesHint = nil
            return
        }
        workspaceChangesHint = store.workspaceChangesHint(
            workspaceID: workspace.rpcWorkspaceID.rawValue
        )
    }
}
#endif
