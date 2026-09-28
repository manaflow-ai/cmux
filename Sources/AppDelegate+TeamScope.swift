import CmuxCloud
import AppKit

extension AppDelegate {
    /// Closes local Cloud projections before a team switch so an old team's
    /// terminals, browser URLs, and reconnect configuration cannot leak into
    /// the newly-selected team.
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
                    clearConfiguration: true,
                    disconnectedDetail: detail
                )
                if manager.tabs.count > 1 {
                    manager.closeWorkspace(workspace, recordHistory: false)
                } else {
                    workspace.withClosedPanelHistorySuppressed {
                        workspace.teardownAllPanels()
                    }
                }
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
