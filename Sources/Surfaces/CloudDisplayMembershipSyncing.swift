import Foundation

/// Persists a local VNC view in the VM's revisioned Cloud workspace projection.
@MainActor
protocol CloudDisplayMembershipSyncing: AnyObject {
    func cloudDisplayMembershipWorkspace(
        displayID: String,
        panelID: UUID
    ) async throws -> String?

    func syncCloudDisplayMembership(
        displayID: String,
        workspaceID: String,
        panelID: UUID,
        attached: Bool
    ) async throws

    /// Removes `displayID` from the workspace for every client and view.
    func removeCloudDisplay(displayID: String, fromWorkspace workspaceID: String) async throws
}
