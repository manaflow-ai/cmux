public import CmuxNextDaemon

public extension Sequence where Element == DaemonService {
    /// The listed workspace whose public id is `id`, on the first of these daemons that lists it (`MachineRegistry.daemons`
    /// is local first): the one `allWorkspaces.first { $0.0.resourceID?.rawValue == id }` finds, from each store's own
    /// resource index (`DaemonStore.workspace(resourceID:)`). A link or a lookup costs one probe per machine, not a copy
    /// and a walk of every workspace. Each probe reads its store's `workspaces`, as `allWorkspaces` does, so a tracked
    /// caller still hears a workspace come or go.
    @MainActor func workspace(resourceID id: String) -> (WorkspaceModel, DaemonService)? {
        let resource = ResourceID(rawValue: id)
        for daemon in self {
            if let workspace = daemon.store.workspace(resourceID: resource) { return (workspace, daemon) }
        }
        return nil
    }
}
