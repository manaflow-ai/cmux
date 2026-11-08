import AppKit

extension AppDelegate {
    /// Closes every local workspace attached to a Cloud machine without
    /// touching the machine's registration. The remote machine and its
    /// terminals are unaffected, so the machine can be opened again if a
    /// delete that closed these workspaces fails.
    func closeLocalWorkspaces(forCloudVMID vmID: String) {
        for (manager, doomed) in localWorkspaces(forCloudVMID: vmID) {
            for workspace in doomed {
                if manager.tabs.count > 1 {
                    manager.closeWorkspace(workspace, recordHistory: false)
                } else {
                    // TabManager intentionally keeps the final workspace as a
                    // local anchor. Clear its cloud binding and panels instead
                    // of leaving a deleted VM's loading/connected surface
                    // behind when this is the only tab in the window.
                    workspace.disconnectRemoteConnection(clearConfiguration: true)
                    workspace.cloudVMBinding = nil
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

    private func localWorkspaces(forCloudVMID vmID: String) -> [(manager: TabManager, workspaces: [Workspace])] {
        let target = vmID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return [] }
        var managers = mainWindowContexts.values.map(\.tabManager)
        if let tabManager, !managers.contains(where: { $0 === tabManager }) {
            managers.append(tabManager)
        }
        return managers.map { manager in
            (manager, manager.tabs.filter { $0.cloudVMID?.lowercased() == target })
        }
    }
}
