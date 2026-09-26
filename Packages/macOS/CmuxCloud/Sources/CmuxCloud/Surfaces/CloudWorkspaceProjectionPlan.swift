import CmuxSurfaceCatalogModel
import Foundation

/// Exact daemon tab identities determine membership; a shared terminal process
/// can have several independent views, and closing one never closes the others.
public struct CloudWorkspaceProjectionPlan {
    public let missing: [SurfaceResourcePlacement]
    public let obsolete: [SurfaceProjection]

    public init(desired: [SurfaceResourcePlacement], existing: [SurfaceProjection]) {
        let wanted = Set(desired)
        var seen = Set<SurfaceResourcePlacement>()
        var obsolete: [SurfaceProjection] = []
        for projection in existing.sorted(by: { $0.panelID.uuidString < $1.panelID.uuidString }) {
            let placement = SurfaceResourcePlacement(
                resource: projection.resource, remoteWorkspaceID: projection.remoteWorkspaceID,
                remoteTabID: projection.remoteTabID
            )
            // A local preview has no daemon tab but retains the bound remote
            // workspace as its local-view provenance. It satisfies its desired
            // workspace row and is never retired by the graph. A projection whose
            // coordinates were cleared by an authoritative remote deletion has
            // neither coordinate and must still be retired.
            if projection.isLocalWorkspaceView && projection.remoteWorkspaceID != nil {
                seen.insert(placement)
                continue
            }
            if !wanted.contains(placement) || !seen.insert(placement).inserted { obsolete.append(projection) }
        }
        var missingSeen = Set<SurfaceResourcePlacement>()
        missing = desired.filter { !seen.contains($0) && missingSeen.insert($0).inserted }
        self.obsolete = obsolete
    }
}
