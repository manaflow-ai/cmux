import Foundation

extension SurfaceCatalog {
    /// Creation and opening share the placement policy. The guest resource stays
    /// on its VM if the selected destination disappears during creation.
    func createDisplay(on machine: SurfaceMachineID, into destination: SurfaceDestination) async throws {
        guard Workspace.liveWorkspace(id: destination.workspaceID) != nil else {
            throw SurfaceCatalogError.destinationNotFound(destination.workspaceID.uuidString)
        }
        let identity = SurfaceResourceID(machine: machine, kind: .display, key: "new")
        try validateOwnership(of: [identity], at: destination)
        guard let provider = provider(for: machine) as? CmuxTuiSurfaceProvider else {
            throw SurfaceCatalogError.noProvider(machine)
        }
        let resource = try await provider.createDisplay()
        try Task.checkCancellation()
        try validateOwnership(of: [resource.id], at: destination)
        guard self.provider(for: machine) === provider else { throw CancellationError() }
        _ = try await project(resource.id, into: destination, focus: true, reuseExisting: false)
    }
}
