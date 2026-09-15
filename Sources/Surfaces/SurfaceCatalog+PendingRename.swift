import Foundation

extension SurfaceCatalog {
    /// Intent remains protected after the RPC returns, until the daemon's accepted
    /// graph passes its receipt. A process-title or notification event in that gap
    /// cannot turn an old tab name into a new local rename.
    func pendingCloudRenameName(for key: CloudRenameCoordinator.Key) -> String? {
        if let name = cloudRenameCoordinator.pendingName(for: key) { return name }
        return cloudStateObservations[key.machine]?.pendingWrites?.first { write in
            switch key.scope {
            case .workspace: return write.kind == .workspaceRename && write.remoteWorkspaceID == key.remoteID
            case .tab: return write.kind == .tabRename && write.remoteTabID == key.remoteID
            case .terminal: return false
            }
        }?.name
    }
}
