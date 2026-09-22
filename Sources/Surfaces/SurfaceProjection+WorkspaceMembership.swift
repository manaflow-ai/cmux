extension SurfaceProjection {
    /// Desktop and port previews created on this Mac have no daemon tab.
    var isLocalWorkspaceView: Bool {
        remoteTabID == nil && (resource.kind == .display || resource.isForwardedPort)
    }

    /// Explicit previews have no daemon tab. Their live catalog projections name
    /// their bound workspace; availability in the machine resource pool never does.
    /// A daemon placement of the same resource already supplies that workspace row.
    static func localWorkspaceMembers(resources: [SurfaceResource], projections: [SurfaceProjection]) -> [(resource: SurfaceResource, workspaceID: String)] {
        let previews = Dictionary(uniqueKeysWithValues: resources.filter { $0.kind == .display || $0.id.isForwardedPort }.map { ($0.id, $0) })
        var seen: [SurfaceResourceID: Set<String>] = [:]
        return projections.compactMap { projection in
            guard projection.isLocalWorkspaceView,
                  let workspaceID = projection.remoteWorkspaceID,
                  let resource = previews[projection.resource],
                  !resource.remoteWorkspaces.contains(where: { $0.id == workspaceID }),
                  seen[resource.id, default: []].insert(workspaceID).inserted else { return nil }
            return (resource, workspaceID)
        }
    }
}
