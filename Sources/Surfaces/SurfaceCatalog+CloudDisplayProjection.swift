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
        // Recording or restoring a daemon tab never replays a remote move; its
        // recorded coordinates are reconciled against the accepted graph.
        guard resolved.isLocalWorkspaceView else { return }
        cloudPlacementCoordinator.projectionDidMove(resolved, catalog: self)
    }

    /// Records a pane this catalog just materialized and syncs its placement.
    func recordMaterializedProjection(_ projection: SurfaceProjection) {
        record(projection)
        replayMaterializedCloudPlacement(projection)
    }

    /// A newly materialized daemon tab syncs its placement once, as it did
    /// before local display membership moved into ``recordCloudProjection``.
    func replayMaterializedCloudPlacement(_ projection: SurfaceProjection) {
        guard !projection.isLocalWorkspaceView else { return }
        cloudPlacementCoordinator.projectionDidMove(projection, catalog: self)
    }
}
