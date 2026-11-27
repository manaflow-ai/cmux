import CmuxSurfaceCatalogModel
import Foundation

extension Workspace {
    /// The owning team of every Cloud machine this workspace shows, persisted
    /// so its panes reconnect with that team after a restart even when another
    /// team is selected. Nil when the workspace shows no Cloud machine.
    var cloudMachineTeamsForSession: [String: String]? {
        var machineIDs = Set((surfaceProjectionRecordsForSession ?? []).compactMap(\.resource.machine.cloudMachineID))
        if let binding = cloudVMBinding, !binding.vmID.hasPrefix("ssh:") { machineIDs.insert(binding.vmID) }
        var teams: [String: String] = [:]
        for machineID in machineIDs {
            let previous = cloudVMBinding?.vmID == machineID ? cloudVMBinding : nil
            if let team = WorkspaceCloudVMBinding.owningTeamID(forVMID: machineID, previous: previous) {
                teams[machineID] = team
            }
        }
        return teams.isEmpty ? nil : teams
    }

    /// Hands persisted owning teams to the Cloud registry before panes restore.
    func adoptRestoredCloudMachineTeams(_ snapshot: SessionWorkspaceSnapshot) {
        let registry = CmuxTuiSurfaceProviderRegistry.shared
        for (machineID, teamID) in snapshot.cloudMachineTeams ?? [:] {
            registry.adoptOwnerTeam(teamID, forMachineID: machineID)
        }
        if let binding = snapshot.cloudVM {
            registry.adoptOwnerTeam(binding.teamID, forMachineID: binding.vmID)
        }
    }
}
