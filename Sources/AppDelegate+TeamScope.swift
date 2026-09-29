import CmuxCloud
import AppKit

extension AppDelegate {
    /// Suspends Cloud access before a team switch while preserving local layout,
    /// scrollback, and bindings for the newly-selected team to recover.
    @MainActor
    func prepareCloudVMAccessForTeamSwitch() {
        SurfaceCatalog.shared.cloudWorkspaceCreationCoordinator.cancelAll()
        CloudVMActionLauncher.shared.cancelAllForAuthTransition()
        let detail = String(
            localized: "machines.teamSwitch.disconnectedDetail",
            defaultValue: "Cloud VM access moved to another team."
        )
        for manager in liveWorkspaceIdentityTabManagers() {
            let cloudWorkspaces = manager.tabs.filter { workspace in
                workspace.isManagedCloudVMWorkspace ||
                    workspace.panels.values.contains { $0.panelType == .cloudVMLoading }
            }
            for workspace in cloudWorkspaces {
                workspace.disconnectRemoteConnection(
                    clearConfiguration: false,
                    disconnectedDetail: detail
                )
            }
        }
        ClosedItemHistoryStore.shared.removeManagedCloudVMRecords()
        cloudWorkspaceOperationController?.cancelAll()
        cloudTunnelAccessDidEnd()
        NotificationCenter.default.post(
            name: .cmuxCloudVMAccessDidEnd,
            object: self,
            userInfo: ["cmux.teamSwitch": true]
        )
    }
}
