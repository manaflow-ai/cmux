import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// The accepted daemon projection rows that describe VNC membership. This is
    /// derived at snapshot time so the tree never reads a local pane as remote
    /// authority.
    func cloudDisplayMemberships() -> [CloudVMDisplayMembership] {
        let knownDisplayIDs = Set(resources.keys.filter { $0.kind == .display })
        return cloudStates.values
            .flatMap(\.displayMemberships)
            .filter {
                knownDisplayIDs.contains(SurfaceResourceID(
                    machine: $0.machine, kind: .display, key: $0.displayID
                ))
            }
            .sorted {
                ($0.machine.rawValue, $0.workspaceID, $0.displayID, $0.clientID, $0.viewID)
                    < ($1.machine.rawValue, $1.workspaceID, $1.displayID, $1.clientID, $1.viewID)
            }
    }

    /// Reconstructs one accepted frontend display view from the catalog's
    /// authoritative projection. This is the materialization boundary for a
    /// workspace row on a client that has no corresponding daemon display tab.
    func cloudDisplayMembershipView(
        for resource: SurfaceResourceID,
        workspaceID: String,
        viewID: String? = nil
    ) -> SurfaceRemoteView? {
        guard resource.kind == .display else { return nil }
        let matches = cloudDisplayMemberships().filter {
            $0.machine == resource.machine && $0.displayID == resource.key && $0.workspaceID == workspaceID
                && (viewID == nil || $0.viewID == viewID)
        }
        guard matches.count == 1, let membership = matches.first,
              let workspace = machines[resource.machine]?.remoteWorkspaces?.first(where: { $0.id == workspaceID })
                  ?? cloudStates[resource.machine]?.workspaces.first(where: { $0.id == workspaceID }).map({
                      SurfaceRemoteWorkspace(id: $0.id, name: $0.name, index: $0.index, focused: $0.focused)
                  }) else { return nil }
        return SurfaceRemoteView(
            tabID: SurfaceRemoteView.cloudDisplayMembershipViewPrefix + membership.viewID,
            workspace: workspace,
            name: nil,
            index: nil,
            focused: false
        )
    }

    /// Resolves the exact placement token carried by a workspace group. A
    /// frontend display view has no daemon tab id, so its marker is resolved
    /// against the accepted projection instead of the base display resource.
    func remoteView(
        for placement: SurfaceResourcePlacement,
        fallbackWorkspaceID: String? = nil
    ) throws -> SurfaceRemoteView? {
        let workspaceID = placement.remoteWorkspaceID ?? fallbackWorkspaceID
        if let membershipViewID = placement.cloudDisplayMembershipViewID {
            guard let workspaceID,
                  let view = cloudDisplayMembershipView(
                      for: placement.resource,
                      workspaceID: workspaceID,
                      viewID: membershipViewID
                  ) else {
                throw SurfaceCatalogError.unavailable(
                    placement.resource,
                    reason: "Cloud display membership is no longer present"
                )
            }
            return view
        }
        if let resource = resources[placement.resource],
           placement.remoteTabID == nil,
           resource.remoteViews == nil,
           (resource.kind == .display || resource.id.isForwardedPort) {
            // Displays and forwarded ports can be local previews in more than
            // one bound workspace. They have no daemon tab or membership row
            // to resolve, so an absent membership is a valid local placement.
            // Keep the accepted membership view when one exists, but do not
            // turn a missing preview membership into a reconcile failure.
            if resource.kind == .display,
               let workspaceID,
               let view = cloudDisplayMembershipView(for: placement.resource, workspaceID: workspaceID) {
                return view
            }
            return nil
        }
        return try remoteView(
            for: placement.resource,
            tabID: placement.remoteTabID,
            workspaceID: workspaceID
        )
    }

    /// Resolves a group placement without allowing a missing display tab to
    /// fall back to an unrelated resource view.
    func resolveRemoteView(
        for member: SurfaceResourcePlacement,
        fallbackWorkspaceID: String?
    ) throws -> SurfaceRemoteView? {
        guard resources[member.resource] != nil else { return nil }
        if member.cloudDisplayMembershipViewID == nil, member.remoteTabID == nil,
           let workspaceID = member.remoteWorkspaceID ?? fallbackWorkspaceID,
           projections.contains(where: {
               $0.resource == member.resource && $0.isLocalWorkspaceView && $0.remoteWorkspaceID == workspaceID
           }) {
            return nil
        }
        return try remoteView(for: member, fallbackWorkspaceID: fallbackWorkspaceID)
    }

    /// Resolves an agent-provided remote placement against the latest accepted
    /// graph. A workspace id alone is valid only when it identifies one view;
    /// callers that need a particular tab must provide `tabID`.
    func remoteView(
        for id: SurfaceResourceID,
        tabID: String? = nil,
        workspaceID: String? = nil
    ) throws -> SurfaceRemoteView? {
        guard let resource = resources[id] else { throw SurfaceCatalogError.unknownResource(id) }
        if let tabID, tabID.hasPrefix(SurfaceRemoteView.cloudDisplayMembershipViewPrefix) {
            let membershipViewID = String(tabID.dropFirst(SurfaceRemoteView.cloudDisplayMembershipViewPrefix.count))
            guard resource.kind == .display,
                  !membershipViewID.isEmpty,
                  let workspaceID,
                  let view = cloudDisplayMembershipView(
                      for: id,
                      workspaceID: workspaceID,
                      viewID: membershipViewID
                  ) else {
                throw SurfaceCatalogError.unavailable(id, reason: "Cloud display membership is no longer present")
            }
            return view
        }
        guard let views = resource.remoteViews else {
            if tabID != nil || workspaceID != nil {
                throw SurfaceCatalogError.unavailable(id, reason: "remote placement data is unavailable")
            }
            return nil
        }
        if let tabID {
            let matches = views.filter { $0.tabID == tabID }
            guard matches.count == 1, let view = matches.first else {
                if matches.count > 1 {
                    throw SurfaceCatalogError.unavailable(id, reason: "remote tab \(tabID) has ambiguous placement")
                }
                throw SurfaceCatalogError.unavailable(id, reason: "remote tab \(tabID) is no longer present")
            }
            if let workspaceID, view.workspace.id != workspaceID {
                throw SurfaceCatalogError.unavailable(id, reason: "remote tab \(tabID) is not in workspace \(workspaceID)")
            }
            return view
        }
        guard let workspaceID else { return nil }
        let matches = views.filter { !$0.isCloudDisplayMembershipView && $0.workspace.id == workspaceID }
        guard matches.count <= 1 else {
            throw SurfaceCatalogError.ambiguousRemotePlacement(id, workspaceID: workspaceID)
        }
        guard let view = matches.first else {
            if resource.kind == .display, views.contains(where: \.isCloudDisplayMembershipView) { return nil }
            throw SurfaceCatalogError.unavailable(id, reason: "remote workspace \(workspaceID) has no view of this resource")
        }
        return view
    }

}
