import AppKit

extension AppDelegate {
    /// Closes every local workspace attached to a Cloud machine without
    /// touching the machine's registration. The remote machine and its
    /// terminals are unaffected, so the machine can be opened again if a
    /// delete that closed these workspaces fails.
    func closeLocalWorkspaces(forCloudVMID vmID: String) {
        let target = vmID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty else { return }
        var managers = mainWindowContexts.values.map(\.tabManager)
        if let tabManager, !managers.contains(where: { $0 === tabManager }) {
            managers.append(tabManager)
        }
        for manager in managers {
            let doomed = manager.tabs.filter { workspace in
                workspace.cloudVMID?.lowercased() == target
            }
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
}
