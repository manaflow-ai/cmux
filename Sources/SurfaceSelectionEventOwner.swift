import Foundation

/// Defines the lifecycle hooks required by panel-owned selection sources.
@MainActor
protocol SurfaceSelectionEventOwner: AnyObject {
    var id: UUID { get }
    var surfaceSelectionEventCoordinator: SurfaceSelectionEventCoordinator { get }

    func detachSurfaceSelectionEvents()
    func reattachSurfaceSelectionEvents()
}

extension SurfaceSelectionEventOwner {
    func detachSurfaceSelectionEvents() {
        surfaceSelectionEventCoordinator.webBridgeRegistry.detach(surfaceId: id)
        surfaceSelectionEventCoordinator.publisher.unregister(surfaceId: id)
    }

    func reattachSurfaceSelectionEvents() {}
}
