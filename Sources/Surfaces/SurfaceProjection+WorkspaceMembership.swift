extension SurfaceProjection {
    /// Explicit VNC panes have no daemon tab. Their live catalog projections name
    /// their bound workspace; availability in the machine display pool never does.
    /// A daemon placement of the same display already supplies that workspace row.
    static func localDisplayMembers(resources: [SurfaceResource], projections: [SurfaceProjection]) -> [(resource: SurfaceResource, workspaceID: String)] {
        let displays = Dictionary(uniqueKeysWithValues: resources.filter { $0.kind == .display }.map { ($0.id, $0) })
        var seen: [SurfaceResourceID: Set<String>] = [:]
        return projections.compactMap { projection in
            guard projection.remoteTabID == nil,
                  let workspaceID = projection.remoteWorkspaceID,
                  let resource = displays[projection.resource],
                  !resource.remoteWorkspaces.contains(where: { $0.id == workspaceID }),
                  seen[resource.id, default: []].insert(workspaceID).inserted else { return nil }
            return (resource, workspaceID)
        }
    }
}
