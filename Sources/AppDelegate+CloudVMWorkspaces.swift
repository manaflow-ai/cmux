import Foundation

extension AppDelegate {
    /// Every open workspace bound to Cloud VM `vmID` through
    /// `workspace.cloud_vm_bind`, across all main windows. The Cloud VM host
    /// gate uses this set to scope what a machine may address: nothing
    /// outside these workspaces is reachable from that machine.
    func workspaces(boundToCloudVM vmID: String) -> [Workspace] {
        var managers: [TabManager] = mainWindowContexts.values.map(\.tabManager)
        if let tabManager, !managers.contains(where: { $0 === tabManager }) {
            managers.append(tabManager)
        }
        var seen = Set<UUID>()
        var result: [Workspace] = []
        for manager in managers {
            for workspace in manager.tabs where workspace.cloudVMBinding?.vmID == vmID {
                guard seen.insert(workspace.id).inserted else { continue }
                result.append(workspace)
            }
        }
        return result
    }
}
