import Foundation

/// Exact daemon tab identities determine membership; a shared terminal process
/// can have several independent views, and closing one never closes the others.
struct CloudWorkspaceProjectionPlan {
    let missing: [SurfaceResourcePlacement]
    let obsolete: [SurfaceProjection]

    init(desired: [SurfaceResourcePlacement], existing: [SurfaceProjection]) {
        let wanted = Set(desired)
        var seen = Set<SurfaceResourcePlacement>()
        var obsolete: [SurfaceProjection] = []
        for projection in existing.sorted(by: { $0.panelID.uuidString < $1.panelID.uuidString }) {
            let placement = SurfaceResourcePlacement(
                resource: projection.resource, remoteWorkspaceID: projection.remoteWorkspaceID,
                remoteTabID: projection.remoteTabID
            )
            if !wanted.contains(placement) || !seen.insert(placement).inserted { obsolete.append(projection) }
        }
        var missingSeen = Set<SurfaceResourcePlacement>()
        missing = desired.filter { !seen.contains($0) && missingSeen.insert($0).inserted }
        self.obsolete = obsolete
    }
}
