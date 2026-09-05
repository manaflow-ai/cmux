import Foundation

extension CloudTunnelCoordinator {
    /// The production coordinator: backend from this build's signature and
    /// bundle, NetworkExtension controller when it is available, enrollment
    /// through the signed-in ``VMClient``. Main actor because the controller
    /// is.
    @MainActor
    static func live(
        consumers: any CloudTunnelConsumerSource,
        selector: CloudTunnelBackendSelector = .live(),
        tunnelManager: VMTunnelManager = VMTunnelManager()
    ) -> CloudTunnelCoordinator {
        let backend = selector.select()
        let controller: any CloudTunnelControlling
        switch backend {
        case .networkExtension(let extensionBundleIdentifier):
            controller = NetworkExtensionTunnelController(providerBundleIdentifier: extensionBundleIdentifier)
        case .unavailable:
            controller = CloudTunnelInertController()
        }
        return CloudTunnelCoordinator(
            backend: backend,
            controller: controller,
            enroller: VMTunnelEnroller(manager: tunnelManager),
            consumers: consumers
        )
    }
}
