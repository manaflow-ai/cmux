import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import CmuxFoundation

extension CmuxTuiSurfaceProvider {
    var supportsDisplayCreation: Bool {
        // The stored machine kind predates the desktop capability contract and
        // is stale on some VMs that already have the validated runtime. The
        // display coordinator's live guest probe is the authority; retain the
        // local checks that prevent requests while asleep or detached.
        isAwake && info.hasDesktop
    }

    var displayResources: [SurfaceResource] {
        if let snapshot = displayCoordinator.displaySnapshot {
            return snapshot.displays.map { $0.resource(on: machine, address: info.privateAddress) }
        }
        return [CmuxTuiSnapshotParser.display(machine: machine,
            directURL: info.privateAddress.map { Self.privateDesktopURL(privateAddress: $0) })]
    }

    /// Only a user-requested refresh/expansion performs guest discovery. Results
    /// may publish only through the same still-authorized provider instance.
    func refreshDisplays() async {
        guard isAwake, info.hasDesktop else { return }
        let generation = currentLifecycleGeneration
        let refresh = refreshGeneration
        await displayCoordinator.refresh()
        guard isCurrentRefresh(lifecycle: generation, refresh: refresh) else { return }
        publishDisplays()
    }

    func createDisplay() async throws -> SurfaceResource {
        guard supportsDisplayCreation else { throw SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage) }
        // No discovery round trip first: the create command installs the guest
        // helper itself and its reply is the full catalog, so a prior `list`
        // only added a second VM exec (about two seconds) to the first click.
        let generation = currentLifecycleGeneration
        defer {
            if isCurrentLifecycleGeneration(generation), isRegisteredInCatalog() { publishDisplays() }
        }
        let snapshot = try await displayCoordinator.create()
        guard isCurrentLifecycleGeneration(generation), isRegisteredInCatalog() else { throw CancellationError() }
        guard let display = snapshot.displays.first(where: { $0.id == snapshot.created }) else {
            throw SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage)
        }
        return display.resource(on: machine, address: info.privateAddress)
    }

    private func publishDisplays() {
        let resources = displayResources
        let desiredIDs = Set(resources.map(\.id))
        for resource in catalog.snapshot.resources(on: machine)
            where resource.kind == .display && !desiredIDs.contains(resource.id) {
            catalog.remove(resource.id, from: self)
        }
        for var resource in resources {
            // Guest discovery owns the connection, while the daemon/catalog
            // owns existing view placements. Refresh must preserve both.
            if let existing = catalog.resources[resource.id] {
                resource.remoteViews = existing.remoteViews
                resource.remoteWorkspace = existing.remoteWorkspace
            }
            catalog.upsert(resource, from: self)
        }
        catalog.notifyChange()
    }

    /// The noVNC URL retains each display's own port across VM reconnects.
    nonisolated static func privateDesktopURL(privateAddress: String, port: Int = CmuxTuiSnapshotParser.desktopPort) -> String {
        CloudGuestDisplay.privateDesktopURL(privateAddress: privateAddress, port: port)
    }
}
