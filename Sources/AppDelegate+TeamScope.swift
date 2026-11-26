import CmuxCloud
import AppKit

extension AppDelegate {
    /// Prepares local Cloud state before the selected team changes.
    ///
    /// - Parameter isSameAccount: True when the same account selects another
    ///   team. Open Cloud terminals and browsers are owned by the team that
    ///   created them and name that team on every request, so they stay open,
    ///   connected, and interactive; only work that would land in the previous
    ///   selection (pending creates and actions) is cancelled. False when the
    ///   account itself changed: every Cloud projection closes so one account's
    ///   terminals, browser URLs, and reconnect configuration cannot leak into
    ///   another account.
    @MainActor
    func prepareCloudVMAccessForTeamSwitch(isSameAccount: Bool) {
        SurfaceCatalog.shared.cloudWorkspaceCreationCoordinator.cancelAll()
        CloudVMActionLauncher.shared.cancelAllForAuthTransition()
        cloudWorkspaceOperationController?.cancelAll()
        if isSameAccount {
            // A create that already produced a machine keeps it in the team
            // that owns it; the person sees it again from that team.
            MachineCreateCoordinator.shared.cancelAllForAuthTransition(cleanupCreatedMachines: false)
            return
        }
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
        cloudTunnelAccessDidEnd()
        NotificationCenter.default.post(name: .cmuxCloudVMAccessDidEnd, object: self)
    }
}
