import Foundation

/// Execution ownership exists before a terminal has an attached projection.
/// A missing resource/provider is a Cloud failure, never permission to run locally.
@MainActor
struct CloudTerminalCreationTarget {
    enum Source {
        case projection(SurfaceProjection)
        case pending(CloudTerminalPaneReservation)
        case workspace(WorkspaceCloudVMBinding)
        case machine(remoteWorkspaceID: String?)
    }
    struct Anchor {
        let resource: SurfaceResource?
        let remoteWorkspaceID: String?
        let remoteTabID: String?
    }

    let machine: SurfaceMachineID
    let source: Source

    func resolve(in workspace: Workspace, catalog: SurfaceCatalog) async throws -> Anchor {
        let projection: SurfaceProjection
        switch source {
        case .pending(let reservation):
            projection = try await reservation.resolution.value()
        case .projection(let existing):
            projection = existing
        case .workspace(let binding):
            guard let id = binding.remoteWorkspaceID, !id.isEmpty else { throw CloudDiagnosticFailure.notFound }
            return Anchor(resource: nil, remoteWorkspaceID: id, remoteTabID: nil)
        case .machine(let id):
            return Anchor(resource: nil, remoteWorkspaceID: id, remoteTabID: nil)
        }
        guard workspace.panels[projection.panelID] != nil,
              let current = catalog.projection(forPanel: projection.panelID),
              current.workspaceID == workspace.id, current.resource.machine == machine,
              let resource = catalog.resources[current.resource] else { throw CloudDiagnosticFailure.notFound }
        let remote = catalog.cloudPlacementCoordinator.creationWorkspaceID(
            in: workspace.id, near: resource, preferredRemoteWorkspaceID: current.remoteWorkspaceID
        )
        guard remote != nil || current.remoteTabID != nil else {
            throw SurfaceCatalogError.ambiguousRemotePlacement(resource.id, workspaceID: "")
        }
        return Anchor(resource: resource, remoteWorkspaceID: remote, remoteTabID: current.remoteTabID)
    }
}
