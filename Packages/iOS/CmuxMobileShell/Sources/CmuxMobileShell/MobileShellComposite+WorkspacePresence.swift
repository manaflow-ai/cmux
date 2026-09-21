import Foundation

extension MobileShellComposite {
    func announceWorkspacePresence() {
        let scope: String? = selectedWorkspace.flatMap { workspace in
            let remoteID = workspace.rpcWorkspaceID.rawValue
            if let macDeviceID = workspace.macDeviceID, !macDeviceID.isEmpty {
                return "cloud:\(macDeviceID):\(remoteID)"
            }
            return "local:\(remoteID)"
        }
        Task { [presenceAnnouncer] in await presenceAnnouncer?.setWorkspaceScope(scope) }
    }

    func clearWorkspacePresence() {
        Task { [presenceAnnouncer] in await presenceAnnouncer?.setWorkspaceScope(nil) }
    }
}
