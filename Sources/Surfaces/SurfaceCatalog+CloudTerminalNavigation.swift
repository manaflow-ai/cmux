import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog: CloudTerminalNavigationCatalog {
    func localWorkspaceShowing(remoteWorkspaceID: String, placements: [SurfaceResourcePlacement]) -> UUID? {
        CloudTreeNodeBuilder.localWorkspaceShowing(
            remoteWorkspaceID: remoteWorkspaceID, placements: placements, snapshot: snapshot
        )
    }

    func projectTerminal(_ resource: SurfaceResourceID, in workspaceID: UUID, view: SurfaceRemoteView?) async throws -> SurfaceProjection {
        let opened: (projection: SurfaceProjection, reused: Bool)
        if let view {
            opened = try await project(
                resource, into: .workspace(id: workspaceID, placement: .tab),
                focus: true, reuseExisting: true, reuseInWorkspace: workspaceID, remoteView: view
            )
        } else {
            opened = try await project(
                resource, into: .workspace(id: workspaceID, placement: .tab),
                focus: true, reuseExisting: true, reuseInWorkspace: workspaceID
            )
        }
        return opened.projection
    }

    func terminalWorkspaceLayout(machine: SurfaceMachineID, workspaceID: String) async -> SurfaceProjectionLayout? {
        await CloudWorkspaceLayoutTranslator.fetch(machine: machine, workspaceID: workspaceID, catalog: self)
    }

    func openTerminalWorkspace(_ group: SurfaceResourceGroup, title: String, layout: SurfaceProjectionLayout?) async throws
        -> (workspaceID: UUID, projections: [SurfaceProjection]) {
        try await projectGroupAsNewLocalWorkspace(group, title: title, focus: true, host: .appOptimistic, layout: layout)
    }

    func bindTerminalWorkspace(localWorkspaceID: UUID, machine: SurfaceMachineID, remoteWorkspaceID: String, generatedTitle: String) {
        bindCloudWorkspace(
            localWorkspaceID: localWorkspaceID, machine: machine, remoteWorkspaceID: remoteWorkspaceID,
            generatedTitle: generatedTitle
        )
    }
}
