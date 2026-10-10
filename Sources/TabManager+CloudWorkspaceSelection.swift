import CmuxCloudMachines
import CmuxSurfaceCatalogModel

/// Adapts the authoritative per-window workspace selection to Cloud targeting.
extension TabManager {
    func recordCloudWorkspaceSelection() {
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
