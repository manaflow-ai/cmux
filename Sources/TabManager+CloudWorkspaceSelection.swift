import CmuxCloudMachines
import CmuxSurfaceCatalogModel

/// Adapts the authoritative per-window workspace selection to Cloud targeting.
extension TabManager {
    func recordCloudWorkspaceSelection() {
        // A Cloud row can be clicked before its local projection is admitted.
        // Preserve that explicit machine context while Cmd-Y refreshes the
        // current selection; the eventual concrete selection replaces it. The
        // willChange callback still sees the old workspace, so only preserve
        // the provisional click while the tracked selection is also that old
        // workspace. Once didChange observes a different workspace, this
        // method records the user's newer Cloud selection.
        if let provisional = cloudWorkspaceSelection.lastCloudSelection,
           provisional.workspaceID == nil,
           provisional.machineID != selectedWorkspace?.cloudVMID,
           cloudWorkspaceSelection.trackedWorkspaceID == selectedTabId {
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
