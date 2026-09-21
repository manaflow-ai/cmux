import CMUXMobileCore
import Foundation

extension MobileShellComposite {
    func announceWorkspaceScopeForSelection() {
        guard let workspace = selectedWorkspace else {
            clearWorkspacePresenceScope()
            return
        }
        guard let ownerID = workspace.macDeviceID,
              let owner = UUID(uuidString: ownerID),
              let workspaceID = UUID(uuidString: workspace.rpcWorkspaceID.rawValue) else {
            clearWorkspacePresenceScope()
            return
        }
        let scope = WorkspacePresenceScope(
            kind: .mac,
            ownerID: owner.uuidString,
            instanceTag: workspace.macInstanceTag ?? "default",
            workspaceID: workspaceID.uuidString
        )
        Task { [workspacePresenceAnnouncer] in
            await workspacePresenceAnnouncer?.setWorkspaceScope(scope)
        }
    }

    func clearWorkspacePresenceScope() {
        Task { [workspacePresenceAnnouncer] in
            await workspacePresenceAnnouncer?.setWorkspaceScope(nil)
        }
    }
}
