import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Registers a Cloud pane and admits its local display membership through
    /// the same placement coordinator used by pane moves and closes.
    func recordCloudProjection(_ projection: SurfaceProjection) {
        let resolved = projection.remoteWorkspaceID == nil
            ? cloudPlacementCoordinator.projectionInCurrentWorkspace(projection)
            : projection
        insertSupersedingLocalPlaceholder(resolved)
        cloudPlacementCoordinator.projectionDidMove(resolved, catalog: self)
    }
}
