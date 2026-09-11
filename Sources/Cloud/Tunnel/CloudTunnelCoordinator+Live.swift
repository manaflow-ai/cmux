import Foundation

extension CloudTunnelCoordinator {
    /// The production coordinator: backend from this build's signature and
    /// bundle, NetworkExtension controller when it is available, enrollment
    /// through the signed-in ``VMClient``, and ``CloudActivationPolicy`` as
    /// the gate on every start. Main actor because the controller is.
    @MainActor
    static func live(
        consumers: any CloudTunnelConsumerSource,
        selector: CloudTunnelBackendSelector = .live(),
        tunnelManager: VMTunnelManager = VMTunnelManager(),
        activation: CloudActivationPolicy? = nil
    ) -> CloudTunnelCoordinator {
        let activation = activation ?? .live(browserTunnel: tunnelManager)
        let backend = selector.select()
        let controller = liveController(for: backend, activation: activation) { identifier in
            NetworkExtensionTunnelController(providerBundleIdentifier: identifier)
        }
        return CloudTunnelCoordinator(
            backend: backend,
            controller: controller,
            enroller: VMTunnelEnroller(manager: tunnelManager),
            consumers: consumers,
            admission: activation.tunnelAdmission
        )
    }

    /// The controller for `backend`. NetworkExtension is used only when the
    /// build can run it, and it is built at launch only when this Mac already
    /// saved a VPN configuration, so a tunnel a previous app instance left
    /// running is still adopted or stopped. On every other Mac the real
    /// controller waits behind ``CloudTunnelDeferredController`` for the first
    /// admitted start: a user who never opted in never loads NetworkExtension
    /// preferences.
    @MainActor
    static func liveController(
        for backend: CloudTunnelBackend,
        activation: CloudActivationPolicy,
        makeNetworkExtensionController: @escaping @MainActor (String) -> any CloudTunnelControlling
    ) -> any CloudTunnelControlling {
        switch backend {
        case .networkExtension(let extensionBundleIdentifier):
            if activation.allowsLaunchTimeTunnelAdoption {
                return makeNetworkExtensionController(extensionBundleIdentifier)
            }
            return CloudTunnelDeferredController {
                makeNetworkExtensionController(extensionBundleIdentifier)
            }
        case .unavailable:
            return CloudTunnelInertController()
        }
    }
}
