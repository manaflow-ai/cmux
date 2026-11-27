import Foundation

/// A system-wide route into the Cloud VM network for a caller that needs one
/// (something outside the app dialing a private address). Nothing the app
/// itself opens uses it: terminals, Ports, and Desktop go through the
/// user-space WireGuard hub, so no in-app path can trigger the extension
/// approval. ``CloudTunnelCoordinator`` is the only implementation.
protocol CloudPrivateNetworkGate: Sendable {
    /// Require a working system route before dialing a private address. This
    /// fails closed on builds without the signed Network Extension.
    func requirePrivateNetworkUse(_ use: CloudPrivateNetworkUse) async throws
}

/// What is about to dial the private network, for logging and consumer
/// accounting.
