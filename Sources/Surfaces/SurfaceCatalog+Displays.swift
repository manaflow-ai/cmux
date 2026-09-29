import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Creates a guest display and publishes it in the machine pool. Projection
    /// into a local workspace is intentionally separate: the guest resource
    /// must survive a missing or changing local destination.
    func createDisplay(on machine: SurfaceMachineID) async throws -> SurfaceResource {
        guard let provider = provider(for: machine) as? CmuxTuiSurfaceProvider else {
            throw SurfaceCatalogError.noProvider(machine)
        }
        let resource = try await provider.createDisplay()
        try Task.checkCancellation()
        guard self.provider(for: machine) === provider else { throw CancellationError() }
        return resource
    }

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
        let resource = try await createDisplay(on: machine)
        try validateOwnership(of: [resource.id], at: destination)
        guard self.provider(for: machine) === provider else { throw CancellationError() }
        _ = try await project(resource.id, into: destination, focus: true, reuseExisting: false)
    }

    /// Creates a display even when the selected workspace is unavailable. If
    /// the destination remains live, the new display is opened there; otherwise
    /// it stays available in the machine's Displays pool.
    func createDisplay(on machine: SurfaceMachineID, into destination: SurfaceDestination?) async throws {
        guard let destination else {
            _ = try await createDisplay(on: machine)
            return
        }
        let resource = try await createDisplay(on: machine)
        guard Workspace.liveWorkspace(id: destination.workspaceID) != nil else { return }
        do {
            try validateOwnership(of: [resource.id], at: destination)
            _ = try await project(resource.id, into: destination, focus: true, reuseExisting: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Guest creation already succeeded. A workspace can disappear or
            // lose ownership while the remote display is starting; leave the
            // display in the pool so it can still be opened from there.
        }
    }
}
