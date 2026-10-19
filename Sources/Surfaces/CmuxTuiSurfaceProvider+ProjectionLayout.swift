import Foundation

extension CmuxTuiSurfaceProvider: SurfaceProjectionLayoutProviding {
    /// Refresh through the provider's ordering fence, then read geometry from the
    /// graph already published to the sidebar. Never join a separate snapshot to
    /// catalog resources captured at a different revision.
    func projectionLayout(workspaceID: String) async throws -> SurfaceProjectionLayout? {
        guard await refreshCurrentGraph(force: true) else {
            throw ProviderError.invalidSnapshot(machineID)
        }
        return catalog.cloudWorkspaceLayout(machine: machine, workspaceID: workspaceID)
    }
}
