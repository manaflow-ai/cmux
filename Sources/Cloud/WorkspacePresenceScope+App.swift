import Foundation
import CMUXMobileCore

extension WorkspacePresenceScope {
    /// Resolves the host-owned scope used by Mac clients and Cloud projections.
    @MainActor static func forWorkspace(_ workspace: Workspace?) -> WorkspacePresenceScope? {
        guard let workspace else { return nil }
        if let binding = workspace.cloudVMBinding,
           let remote = binding.remoteWorkspaceID?.trimmingCharacters(in: .whitespacesAndNewlines),
           let teamID = AppDelegate.shared?.auth?.coordinator.resolvedTeamID {
            return WorkspacePresenceScope(kind: .cloud, ownerID: binding.vmID, workspaceID: remote, teamID: teamID)
        }
        guard let ownerID = UUID(uuidString: MobileHostIdentity.deviceID()) else { return nil }
        return WorkspacePresenceScope(kind: .mac, ownerID: ownerID.uuidString, instanceTag: MobileHostIdentity.instanceTag(), workspaceID: workspace.id.uuidString)
    }
}
