import Foundation

@MainActor
extension CmuxTuiSurfaceProviderRegistry {
    /// Retires disjoint machine queues and port operations concurrently, joining
    /// every cleanup before the registry releases the shared transports.
    static func stopRetiringProviders(_ providers: [CmuxTuiSurfaceProvider]) async {
        await withTaskGroup(of: Void.self) { group in
            for provider in providers {
                group.addTask { @MainActor in await provider.stop() }
            }
        }
    }
}
