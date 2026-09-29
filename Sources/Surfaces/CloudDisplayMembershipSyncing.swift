import Foundation

/// Persists a local VNC view in the VM's revisioned Cloud workspace projection.
@MainActor
protocol CloudDisplayMembershipSyncing: AnyObject {
    func syncCloudDisplayMembership(
        displayID: String,
        workspaceID: String,
        panelID: UUID,
        attached: Bool
    ) async throws
}
