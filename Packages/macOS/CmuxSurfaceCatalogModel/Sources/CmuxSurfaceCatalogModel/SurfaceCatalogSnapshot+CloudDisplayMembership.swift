import Foundation

extension SurfaceCatalogSnapshot {
    /// Returns the machine pool plus one presentation copy for every accepted
    /// display/workspace membership. The copies retain the same resource id and
    /// are used only by workspace rows and groups; the pool remains one row per
    /// discovered display resource. A copy contains only its frontend views, so
    /// an existing daemon display tab is not emitted a second time.
    public func cloudWorkspaceResources(on machine: SurfaceMachineID) -> [SurfaceResource] {
        let base = resources(on: machine)
        let byID = Dictionary(base.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let workspaces = Dictionary(
            (machines.first { $0.id == machine }?.remoteWorkspaces ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result = base
        let membershipsByDisplayID = Dictionary(grouping: cloudDisplayMemberships.filter { $0.machine == machine }, by: \.displayID)
        for displayID in membershipsByDisplayID.keys.sorted() {
            let id = SurfaceResourceID(machine: machine, kind: .display, key: displayID)
            guard let baseResource = byID[id] else { continue }
            var placed = baseResource
            let memberships = (membershipsByDisplayID[displayID] ?? [])
                .sorted { ($0.workspaceID, $0.clientID, $0.viewID) < ($1.workspaceID, $1.clientID, $1.viewID) }
            let views = memberships.enumerated().compactMap { index, membership -> SurfaceRemoteView? in
                guard let workspace = workspaces[membership.workspaceID] else { return nil }
                return SurfaceRemoteView(
                    tabID: SurfaceRemoteView.cloudDisplayMembershipViewPrefix + membership.viewID,
                    workspace: workspace,
                    name: nil,
                    index: index,
                    focused: false
                )
            }
            guard !views.isEmpty else { continue }
            placed.remoteViews = views
            placed.remoteWorkspace = views.first?.workspace
            result.append(placed)
        }
        return result
    }
}
