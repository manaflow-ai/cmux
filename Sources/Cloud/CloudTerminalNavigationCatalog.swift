import Foundation

/// Catalog capabilities consumed by terminal navigation, without owning a catalog or its stores.
@MainActor
protocol CloudTerminalNavigationCatalog: AnyObject {
    func checkCloudWorkspaceNavigation(machine: SurfaceMachineID, workspaceID: String) throws
    func localWorkspaceShowing(remoteWorkspaceID: String, placements: [SurfaceResourcePlacement]) -> UUID?
    func projectTerminal(_ resource: SurfaceResourceID, in workspaceID: UUID, view: SurfaceRemoteView?) async throws -> SurfaceProjection
    func terminalWorkspaceLayout(machine: SurfaceMachineID, workspaceID: String) async -> SurfaceProjectionLayout?
    func openTerminalWorkspace(_ group: SurfaceResourceGroup, title: String, layout: SurfaceProjectionLayout?) async throws
        -> (workspaceID: UUID, projections: [SurfaceProjection])
    func bindTerminalWorkspace(localWorkspaceID: UUID, machine: SurfaceMachineID, remoteWorkspaceID: String, generatedTitle: String)
}
