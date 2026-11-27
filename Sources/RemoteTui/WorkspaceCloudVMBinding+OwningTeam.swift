import Foundation

extension WorkspaceCloudVMBinding {
    /// The team that owns `vmID`: the registry's owning team (a provider, or a
    /// team persisted with a restored pane), else the previous binding's team
    /// for the same machine, else the selected team.
    ///
    /// SSH machines have no team and resolve to nil.
    @MainActor
    static func owningTeamID(forVMID vmID: String, previous: WorkspaceCloudVMBinding?) -> String? {
        guard !vmID.hasPrefix("ssh:") else { return nil }
        if let owner = CmuxTuiSurfaceProviderRegistry.shared.ownerTeamID(forMachineID: vmID) {
            return owner
        }
        if let previous, previous.vmID == vmID, let team = previous.teamID {
            return team
        }
        return AppDelegate.shared?.auth?.coordinator.authenticatedTeamScope?.teamID
    }

    /// This binding with a team, adopting ``owningTeamID(forVMID:previous:)``
    /// when a legacy snapshot restored it without one.
    @MainActor
    func adoptingOwningTeam() -> WorkspaceCloudVMBinding {
        guard teamID == nil else { return self }
        return WorkspaceCloudVMBinding(
            vmID: vmID, isBase: isBase, remoteWorkspaceID: remoteWorkspaceID,
            teamID: Self.owningTeamID(forVMID: vmID, previous: nil)
        )
    }
}
