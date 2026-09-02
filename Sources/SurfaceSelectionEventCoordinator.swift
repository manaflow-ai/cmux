import Foundation
import CmuxSurfaceSelection

/// Owns the selection publisher and WebKit bridge registry for one panel.
@MainActor
final class SurfaceSelectionEventCoordinator {
    let publisher: SurfaceSelectionChangeEventPublisher
    let webBridgeRegistry: SurfaceSelectionWebBridgeRegistry

    init(
        bus: CmuxEventBus = .shared,
        debounceNanoseconds: UInt64 = 100_000_000
    ) {
        let publisher = SurfaceSelectionChangeEventPublisher(
            bus: bus,
            debounceNanoseconds: debounceNanoseconds
        )
        self.publisher = publisher
        self.webBridgeRegistry = SurfaceSelectionWebBridgeRegistry(publisher: publisher)
    }
}
