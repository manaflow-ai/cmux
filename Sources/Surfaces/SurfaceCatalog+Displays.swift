import CmuxSurfaceCatalogModel
import Foundation

extension SurfaceCatalog {
    /// Guest display discovery for a machine whose Displays are on screen. The
    /// guest helper starts a standby display on this request, so the first
    /// New Display hands over a running desktop.
    /// Names a display for every client; an empty name restores "Display N".
    func renameDisplay(_ id: SurfaceResourceID, name: String) async throws {
        guard id.kind == .display, let provider = provider(for: id.machine) as? CmuxTuiSurfaceProvider else {
            throw SurfaceCatalogError.noProvider(id.machine)
        }
        try await provider.renameDisplay(displayID: id.key, name: name)
    }

    /// Returns false, starting nothing, when the machine is asleep or has no desktop.
    func beginDisplayDiscovery(on machine: SurfaceMachineID) -> Bool {
        guard let provider = provider(for: machine) as? CmuxTuiSurfaceProvider,
              provider.supportsDisplayCreation else { return false }
        Task { await provider.refreshDisplays() }
        return true
    }

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
        // A second click while this machine is already creating is dropped, as
        // `createDisplay(on:)` does, before it can flash a pane of its own.
        guard !activeDisplayCreations.contains(machine) else { throw CancellationError() }
        let pane: (workspaceID: UUID, panelID: UUID)
        do {
            pane = try await SurfacePaneFactory.openPreferringSplit(at: destination) { target in
                try SurfacePaneFactory.makeBrowserPane(url: nil, at: target, focus: true)
            }
        } catch {
            // Opening is best effort for the sidebar: still create the display,
            // which then waits in the machine's pool.
            guard bestEffortOpen else { throw error }
            _ = try await createDisplay(on: machine)
            return
        }
        let starting = String(localized: "cloud.display.starting", defaultValue: "Starting display…")
        SurfacePaneFactory.browserPanel(panelID: pane.panelID, in: pane.workspaceID)?.cloudAccess.showStarting(starting)
        // The tab says what the pane is from the click; materializing the
        // display replaces it with the display's name.
        Workspace.liveWorkspace(id: pane.workspaceID)?.setPanelCustomTitle(
            panelId: pane.panelID, title: starting, source: .remote, propagateToCloud: false, catalog: self)
        let resource: SurfaceResource
        do {
            resource = try await createDisplay(on: machine)
        } catch {
            discardReservedDisplayPane(pane, error: error)
            throw error
        }
        let reservation = CloudDisplayPaneReservation(resource: resource.id, workspaceID: pane.workspaceID, panelID: pane.panelID)
        do {
            guard self.provider(for: machine) === provider else { throw CancellationError() }
            try await CloudDisplayPaneReservation.$current.withValue(reservation) {
                _ = try await project(resource.id, into: .workspace(id: pane.workspaceID, placement: .tab), focus: true, reuseExisting: false)
            }
        } catch {
            if projections.contains(where: { $0.panelID == pane.panelID }) == false {
                discardReservedDisplayPane(pane, error: error)
            }
            if error is CancellationError || !bestEffortOpen { throw error }
            // Guest creation already succeeded. The workspace can lose the pane
            // or ownership while the display starts; it stays in the pool.
        }
    }

    /// Closes a reserved pane whose display never arrived. The socket close
    /// refuses a workspace's last surface; that pane shows the failure instead
    /// of spinning on "Starting display…" forever.
    private func discardReservedDisplayPane(_ pane: (workspaceID: UUID, panelID: UUID), error: Error) {
        SurfacePaneFactory.close(panelID: pane.panelID, in: pane.workspaceID)
        guard let browser = SurfacePaneFactory.browserPanel(panelID: pane.panelID, in: pane.workspaceID) else { return }
        browser.cloudAccess.showUnavailable(
            error is CancellationError
                ? String(localized: "cloud.display.creationFailed", defaultValue: "The new display could not start. Refresh Displays, then retry. Existing displays are unchanged.")
                : error.localizedDescription
        )
    }
}
