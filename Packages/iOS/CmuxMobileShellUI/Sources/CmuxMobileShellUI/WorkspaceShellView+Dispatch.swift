import CmuxMobileShell
import CmuxMobileShellModel
import SwiftUI

extension WorkspaceShellView {
    /// Entry availability for the Dispatch composer: the connected Mac must
    /// advertise the capability, and workspace creation must be possible for
    /// the current Mac selection. `nil` hides the affordances.
    var composeDispatchClosure: (() -> Void)? {
        guard store.supportsAgentDispatch, canCreateWorkspaceForMacSelection else { return nil }
        return { showingDispatchComposer = true }
    }

    var dispatchComposerSheet: some View {
        DispatchComposerSheet(
            service: store,
            willLaunch: armDispatchCreatedWorkspaceNavigation,
            launchFailed: disarmDispatchCreatedWorkspaceNavigation,
            finished: { showingDispatchComposer = false }
        )
        .interactiveDismissDisabled(false)
    }

    /// Mirrors the New Workspace flow: snapshot the current workspace ids so
    /// the selection change caused by the created workspace pushes exactly the
    /// new one on the compact stack (under the sheet; revealed on dismiss).
    private func armDispatchCreatedWorkspaceNavigation() {
        pendingCompactCreateNavigationWorkspaceIDs = Set(store.workspaces.map(\.id))
    }

    private func disarmDispatchCreatedWorkspaceNavigation() {
        pendingCompactCreateNavigationWorkspaceIDs = nil
    }
}
