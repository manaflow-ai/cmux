import CmuxCloudMachines

/// Adapts the authoritative per-window workspace selection to Cloud targeting.
extension TabManager {
    func recordCloudWorkspaceSelection() {
        cloudWorkspaceSelection.select(workspaceID: selectedTabId, machineID: selectedWorkspace?.cloudVMID)
    }

    var rememberedCloudWorkspaceSelection: CloudWorkspaceSelection? {
        guard let selection = cloudWorkspaceSelection.lastCloudSelection,
              let workspace = workspacesById[selection.workspaceID],
              workspace.cloudVMID == selection.machineID else { return nil }
        return selection
    }
}
