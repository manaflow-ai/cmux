import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Creates a guest display and publishes it in the machine pool. Projection
    /// into a local workspace is intentionally separate: the guest resource
    /// must survive a missing or changing local destination.
    func createDisplay(on machine: SurfaceMachineID) async throws -> SurfaceResource {
        guard activeDisplayCreations.insert(machine).inserted else { throw CancellationError() }
        // The sidebar shows a pending display row from the click until the
        // guest answers, so creation reads as started immediately.
        notifyChange()
        defer {
            activeDisplayCreations.remove(machine)
            notifyChange()
        }
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
        try await createDisplayInReservedPane(on: machine, at: destination, bestEffortOpen: false)
    }

    /// Creates a display even when the selected workspace is unavailable. If
    /// the destination remains live, the new display is opened there; otherwise
    /// it stays available in the machine's Displays pool.
    func createDisplay(on machine: SurfaceMachineID, into destination: SurfaceDestination?) async throws {
        guard let destination, Workspace.liveWorkspace(id: destination.workspaceID) != nil,
              (try? validateOwnership(of: [SurfaceResourceID(machine: machine, kind: .display, key: "new")], at: destination)) != nil else {
            _ = try await createDisplay(on: machine)
            return
        }
        try await createDisplayInReservedPane(on: machine, at: destination, bestEffortOpen: true)
    }

    /// Opens the pane at the click, showing "Starting display…", then creates the
    /// guest display (a VM round trip) and binds that same pane to it. Creation
    /// failure closes the pane and throws. When opening the created display fails,
    /// the pane closes and the display stays in the machine's pool; that failure
    /// throws only when `bestEffortOpen` is false.
    private func createDisplayInReservedPane(
        on machine: SurfaceMachineID,
        at destination: SurfaceDestination,
        bestEffortOpen: Bool
    ) async throws {
        guard let provider = provider(for: machine) as? CmuxTuiSurfaceProvider else {
            throw SurfaceCatalogError.noProvider(machine)
        }
        let pane = try await SurfacePaneFactory.openPreferringSplit(at: destination) { target in
            try SurfacePaneFactory.makeBrowserPane(url: nil, at: target, focus: true)
        }
        SurfacePaneFactory.browserPanel(panelID: pane.panelID, in: pane.workspaceID)?.cloudAccess.showStarting(
            String(localized: "cloud.display.starting", defaultValue: "Starting display…")
        )
        let reservation = CloudDisplayPaneReservation(machine: machine, workspaceID: pane.workspaceID, panelID: pane.panelID)
        let resource: SurfaceResource
        do {
            resource = try await createDisplay(on: machine)
        } catch {
            SurfacePaneFactory.close(panelID: pane.panelID, in: pane.workspaceID)
            throw error
        }
        do {
            guard self.provider(for: machine) === provider else { throw CancellationError() }
            try await CloudDisplayPaneReservation.$current.withValue(reservation) {
                _ = try await project(resource.id, into: .workspace(id: pane.workspaceID, placement: .tab), focus: true, reuseExisting: false)
            }
        } catch {
            if projections.contains(where: { $0.panelID == pane.panelID }) == false {
                SurfacePaneFactory.close(panelID: pane.panelID, in: pane.workspaceID)
            }
            if error is CancellationError || !bestEffortOpen { throw error }
            // Guest creation already succeeded. The workspace can lose the pane
            // or ownership while the display starts; it stays in the pool.
        }
    }
}
