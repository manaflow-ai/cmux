import CMUXMobileCore
import Foundation

extension MobileShellComposite {
    func announceWorkspaceScopeForSelection() {
        guard let workspace = selectedWorkspace else {
            clearWorkspacePresenceScope()
            return
        }
        let ownerID = workspace.macDeviceID
        let instanceTag = workspace.macInstanceTag ?? "default"
        let workspaceID = workspace.rpcWorkspaceID.rawValue
        let selectedID = selectedWorkspaceID
        Task { @MainActor [weak self, workspacePresenceAnnouncer] in
            guard let self, self.selectedWorkspaceID == selectedID else { return }
            let scope: WorkspacePresenceScope?
            if let ownerID,
               let owner = UUID(uuidString: ownerID),
               let workspace = UUID(uuidString: workspaceID) {
                scope = WorkspacePresenceScope(kind: .mac,
                                               ownerID: owner.uuidString,
                                               instanceTag: instanceTag,
                                               workspaceID: workspace.uuidString)
            } else if let ownerID,
                      let teamID = await self.teamIDProvider(),
                      !teamID.isEmpty {
                scope = WorkspacePresenceScope(kind: .cloud,
                                               ownerID: ownerID,
                                               workspaceID: workspaceID,
                                               teamID: teamID)
            } else {
                scope = nil
            }
            await workspacePresenceAnnouncer?.setWorkspaceScope(scope)
        }
    }

    func clearWorkspacePresenceScope() {
        Task { [workspacePresenceAnnouncer] in
            await workspacePresenceAnnouncer?.setWorkspaceScope(nil)
        }
    }
}
