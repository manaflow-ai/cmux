import CmuxCloudMachines
import CmuxSurfaceCatalogModel

/// Adapts the authoritative per-window workspace selection to Cloud targeting.
extension TabManager {
    func recordCloudWorkspaceSelection() {
        // A Cloud row can be clicked before its local projection is admitted.
        // Preserve that explicit machine context while Cmd-Y refreshes the
        // current selection; the eventual concrete selection replaces it.
        if let provisional = cloudWorkspaceSelection.lastCloudSelection,
           provisional.workspaceID == nil,
           provisional.machineID != selectedWorkspace?.cloudVMID {
            return
        }
        cloudWorkspaceSelection.select(workspaceID: selectedTabId, machineID: selectedWorkspace?.cloudVMID)
    }

    /// Records a clicked Cloud sidebar row before its local projection exists.
    /// The next workspace selection will replace this provisional context with
    /// the concrete local workspace identity.
    func recordCloudWorkspaceSelection(machineID: SurfaceMachineID) {
        cloudWorkspaceSelection.selectCloudMachine(machineID: machineID.rawValue)
    }

    var rememberedCloudWorkspaceSelection: CloudWorkspaceSelection? {
        guard let selection = cloudWorkspaceSelection.lastCloudSelection else { return nil }
        if let workspaceID = selection.workspaceID {
            guard let workspace = workspacesById[workspaceID],
                  workspace.cloudVMID == selection.machineID else { return nil }
        }
        return selection
    }
}
