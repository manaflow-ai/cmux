import Foundation
import CmuxFoundation

extension CmuxTuiSurfaceProvider {
    var supportsDisplayCreation: Bool {
        isAwake && info.hasDesktop && summary.resolvedKind.hasDesktop
            && isRegisteredInCatalog() && displayCoordinator.canCreate
    }

    var displayResources: [SurfaceResource] {
        if let snapshot = displayCoordinator.snapshot {
            return snapshot.displays.map { $0.resource(on: machine, address: info.privateAddress) }
        }
        return [CmuxTuiSnapshotParser.display(machine: machine,
            directURL: info.privateAddress.map { Self.privateDesktopURL(privateAddress: $0) })]
    }

    /// Only a user-requested refresh/expansion performs guest discovery. Results
    /// may publish only through the same still-authorized provider instance.
    func refreshDisplays() async {
        guard isAwake, info.hasDesktop, isRegisteredInCatalog() else { return }
        let generation = currentLifecycleGeneration
        let refresh = refreshGeneration
        await displayCoordinator.refresh()
        guard isCurrentRefresh(lifecycle: generation, refresh: refresh), displayCoordinator.isAvailable else { return }
        publishDisplays()
    }

    func createDisplay() async throws -> SurfaceResource {
        guard supportsDisplayCreation else { throw SurfaceCatalogError.unsupported(CloudGuestDisplaySnapshot.unavailableMessage) }
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
        for var resource in displayResources {
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
        let base = CmuxInternalHostnames.directPortURL(privateAddress: privateAddress, port: port)
        return "\(base)/vnc.html?path=websockify&autoconnect=1&resize=remote&reconnect=1&reconnect_delay=2000"
    }
}
