import Foundation

/// Exact daemon tab identities determine membership; a shared terminal process
/// can have several independent views, and closing one never closes the others.
struct CloudWorkspaceProjectionPlan {
    let missing: [SurfaceResourcePlacement]
    let obsolete: [SurfaceProjection]

    init(desired: [SurfaceResourcePlacement], existing: [SurfaceProjection]) {
        let wanted = Set(desired)
        var seen = Set<SurfaceResourcePlacement>()
        // A display/port preview is a deliberate local view of a Cloud resource.
        // It has no daemon tab identity, so the next bound-workspace snapshot
        // must not mistake it for an obsolete remote placement and close it.
        var localPreviewResources = Set<SurfaceResourceID>()
        var obsolete: [SurfaceProjection] = []
        for projection in existing.sorted(by: { $0.panelID.uuidString < $1.panelID.uuidString }) {
            if projection.isLocalWorkspaceView {
                localPreviewResources.insert(projection.resource)
                continue
            }
            let placement = SurfaceResourcePlacement(
                resource: projection.resource, remoteWorkspaceID: projection.remoteWorkspaceID,
                remoteTabID: projection.remoteTabID
            )
            if !wanted.contains(placement) || !seen.insert(placement).inserted { obsolete.append(projection) }
        }
        var missingSeen = Set<SurfaceResourcePlacement>()
        missing = desired.filter {
            !localPreviewResources.contains($0.resource)
                && !seen.contains($0)
                && missingSeen.insert($0).inserted
        }
        self.obsolete = obsolete
    }
}
