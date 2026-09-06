import Foundation

/// The gate used only by Cloud browser navigation. Terminals and their
/// metadata use the separate user-space WireGuard hub.
protocol CloudPrivateNetworkGate: Sendable {
    /// Require a working route before a browser is allowed to navigate to a
    /// private address. This fails closed.
    func requirePrivateNetworkUse(_ use: CloudPrivateNetworkUse) async throws
}

/// What is about to dial the private network, for logging and consumer
/// accounting.
