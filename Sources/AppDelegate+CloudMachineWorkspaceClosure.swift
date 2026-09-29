import AppKit

extension AppDelegate {
    /// Closes every local workspace attached to a Cloud machine without
    /// touching the machine's registration. The remote machine and its
    /// terminals are unaffected, so the machine can be opened again if a
    /// delete that closed these workspaces fails.
    func closeLocalWorkspaces(forCloudVMID vmID: String) {
        closeLocalWorkspaces(forCloudVMIDs: [vmID])
    }

    /// Closes all local workspaces attached to the given Cloud machines with
    /// one manager/tab scan.
    func closeLocalWorkspaces(forCloudVMIDs vmIDs: Set<String>) {
        let targets = Set(vmIDs.compactMap(Self.normalizedCloudVMID))
        guard !targets.isEmpty else { return }
        for manager in liveWorkspaceIdentityTabManagers(preferredTabManager: tabManager) {
            let doomed = manager.tabs.filter { workspace in
                guard let id = Self.normalizedCloudVMID(workspace.cloudVMID) else { return false }
                return targets.contains(id)
            }
            for workspace in doomed {
                workspace.disconnectRemoteConnection(clearConfiguration: true)
                workspace.cloudVMBinding = nil
                if manager.tabs.count > 1 {
                    manager.closeWorkspace(workspace, recordHistory: false)
                } else {
                    // TabManager intentionally keeps the final workspace as a
                    // local anchor. Clear its cloud binding and panels instead
                    // of leaving a deleted VM's loading/connected surface
                    // behind when this is the only tab in the window.
                    workspace.withClosedPanelHistorySuppressed {
                        workspace.teardownAllPanels()
                    }
                }
            }
        }
    }

    /// The IDs of every local workspace attached to a Cloud machine.
    /// - Parameter vmID: The provider machine identifier, in any case.
    func localWorkspaceIDs(forCloudVMID vmID: String) -> Set<UUID> {
        Set(localWorkspaces(forCloudVMID: vmID).flatMap { $0.workspaces.map(\.id) })
    }

    private static func normalizedCloudVMID(_ vmID: String?) -> String? {
        guard let vmID else { return nil }
        let normalized = vmID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func localWorkspaces(forCloudVMID vmID: String) -> [(manager: TabManager, workspaces: [Workspace])] {
        guard let target = Self.normalizedCloudVMID(vmID) else { return [] }
        return liveWorkspaceIdentityTabManagers(preferredTabManager: tabManager).map { manager in
            (manager, manager.tabs.filter { $0.cloudVMID?.lowercased() == target })
        }
    }
}
