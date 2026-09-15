import CmuxCore
import Foundation

extension SurfaceCatalog {
    /// Builds the one canonical group for a daemon workspace. A resource is
    /// repeated once for every tab placement, so opening a workspace cannot
    /// collapse two tabs that point at the same terminal. Order matches the
    /// Cloud sidebar: panes in layout order, tabs in their stable pane order,
    /// then pane-less resources in kind order.
    func remoteWorkspaceGroup(
        machine: SurfaceMachineID,
        workspaceID: String
    ) throws -> SurfaceResourceGroup {
        let machineSnapshot = snapshot
        let machineInfo = machineSnapshot.machines.first { $0.id == machine }
        var workspace = machineInfo?.remoteWorkspaces?.first { $0.id == workspaceID }
        let resources = machineSnapshot.resources(on: machine)

        struct Candidate {
            let placement: SurfaceResourcePlacement
            let layout: RemoteWorkspacePlacement
        }
        let orderedKinds: [SurfaceResourceKind] = [.terminal, .browser, .display]
        var candidates: [Candidate] = []
        for kind in orderedKinds {
            let kindOrder = kind == .terminal ? 0 : (kind == .browser ? 1 : 2)
            for resource in resources where resource.kind == kind {
                if let views = resource.remoteViews, !views.isEmpty {
                    for view in views where view.workspace.id == workspaceID {
                        workspace = workspace ?? view.workspace
                        candidates.append(Candidate(
                            placement: SurfaceResourcePlacement(resource: resource.id, remoteView: view),
                            layout: RemoteWorkspacePlacement(
                                screenID: view.screenID,
                                paneID: view.paneID,
                                screenIndex: view.screenIndex,
                                paneIndex: view.paneIndex,
                                tabIndex: view.index,
                                focused: view.focused == true,
                                kindOrder: kindOrder
                            )
                        ))
                    }
                } else if resource.remoteViews == nil, let resourceWorkspace = resource.remoteWorkspace,
                          resourceWorkspace.id == workspaceID {
                    workspace = workspace ?? resourceWorkspace
                    candidates.append(Candidate(
                        placement: SurfaceResourcePlacement(
                            resource: resource.id,
                            remoteWorkspaceID: workspaceID
                        ),
                        layout: RemoteWorkspacePlacement(kindOrder: kindOrder)
                    ))
                }
            }
        }

        for member in SurfaceProjection.localDisplayMembers(resources: resources, projections: machineSnapshot.projections)
            where member.workspaceID == workspaceID {
            candidates.append(Candidate(
                placement: SurfaceResourcePlacement(resource: member.resource.id, remoteWorkspaceID: workspaceID),
                layout: RemoteWorkspacePlacement(kindOrder: 2)
            ))
        }

        guard let workspace else {
            throw SurfaceCatalogError.destinationNotFound(
                "workspace \(workspaceID) on \(machine.rawValue)"
            )
        }
        guard !candidates.isEmpty else {
            throw SurfaceCatalogError.destinationNotFound(
                "workspace \(workspaceID) on \(machine.rawValue) has no projectable resources"
            )
        }
        let layout = RemoteWorkspaceLayout(placements: candidates.map(\.layout))
        let placements = layout.flatPlacementIndices.map { candidates[$0].placement }
        return SurfaceResourceGroup(
            title: workspace.name,
            placements: placements,
            remoteWorkspaceID: workspaceID,
            representsWorkspace: true
        )
    }
}
