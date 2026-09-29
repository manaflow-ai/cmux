import Foundation

extension SurfaceCatalogSnapshot {
    /// Returns the machine pool plus one presentation copy for every accepted
    /// display/workspace membership. The copies retain the same resource id and
    /// are used only by workspace rows and groups; the pool remains one row per
    /// discovered display resource.
    public func cloudWorkspaceResources(on machine: SurfaceMachineID) -> [SurfaceResource] {
        let base = resources(on: machine)
        let byID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workspaces = Dictionary(
            (machines.first { $0.id == machine }?.remoteWorkspaces ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result = base
        var seen = Set<String>()
        for membership in cloudDisplayMemberships where membership.machine == machine {
            let id = SurfaceResourceID(machine: machine, kind: .display, key: membership.displayID)
            guard let baseResource = byID[id], let workspace = workspaces[membership.workspaceID],
                  !baseResource.remoteWorkspaces.contains(where: { $0.id == workspace.id }),
                  seen.insert("\(id.rawValue)\u{0}\(workspace.id)").inserted else { continue }
            var placed = baseResource
            placed.remoteViews = nil
            placed.remoteWorkspace = workspace
            result.append(placed)
        }
        return result
    }
}
