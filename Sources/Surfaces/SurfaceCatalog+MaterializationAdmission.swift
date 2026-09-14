import Foundation

extension SurfaceCatalog {
    /// An explicit view is an identity fence, at both admission and commit.
    func validatedRemoteView(_ view: SurfaceRemoteView?, for id: SurfaceResourceID) throws -> SurfaceRemoteView? {
        guard resources[id] != nil else { throw SurfaceCatalogError.unknownResource(id) }
        guard let view else { return nil }
        return try remoteView(for: id, tabID: view.tabID, workspaceID: view.workspace.id)
    }

    func validateMaterializedProjection(_ projection: SurfaceProjection, requestedView: SurfaceRemoteView?) throws {
        try validateMaterializedProjection(projection, requestedTabID: requestedView?.tabID,
                                           requestedWorkspaceID: requestedView?.workspace.id)
    }

    /// Provider work suspends across network reads and pane construction. A
    /// closed or replaced tab cannot become live again when that work returns.
    func validateMaterializedProjection(
        _ projection: SurfaceProjection, requestedTabID: String?, requestedWorkspaceID: String? = nil
    ) throws {
        guard resources[projection.resource] != nil else {
            throw SurfaceCatalogError.unknownResource(projection.resource)
        }
        guard !projection.resource.machine.isLocal,
              let tabID = requestedTabID ?? projection.remoteTabID else { return }
        if requestedTabID == nil, cloudPlacementCoordinator.hasUnobservedPlacement(
            tabID: tabID, on: projection.resource.machine, state: cloudStates[projection.resource.machine]
        ) { return }
        do {
            _ = try remoteView(for: projection.resource, tabID: tabID,
                               workspaceID: requestedWorkspaceID ?? projection.remoteWorkspaceID)
        }
        catch {
            CloudTerminalLifecycleLog().rejected(projection, stage: "materialization-commit")
            throw error
        }
    }
}
