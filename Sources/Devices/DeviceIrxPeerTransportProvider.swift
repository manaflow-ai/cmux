import CMUXMobileCore
import CmuxIrohTransport

/// Carries the intended physical Mac and build through the deferred factory.
struct DeviceIrxPeerTransportProvider: CmxIrohDeferredTransportProviding {
    let client: DeviceIrxClient
    let instance: SurfaceDeviceInstanceID

    func transport(for request: CmxByteTransportRequest) async throws -> any CmxByteTransport {
        try await client.transport(for: request, instance: instance)
    }
}
