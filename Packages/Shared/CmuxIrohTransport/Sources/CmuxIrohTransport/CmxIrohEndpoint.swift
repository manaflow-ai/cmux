public import CMUXMobileCore
public import Foundation

/// One actor-isolated Iroh endpoint generation.
public protocol CmxIrohEndpoint: Sendable {
    /// Returns the stable EndpointID derived from the injected secret key.
    func identity() async -> CmxIrohPeerIdentity

    /// Returns the endpoint's current public reachability snapshot.
    func address() async -> CmxIrohEndpointAddress

    /// Connects to the expected peer using only the supplied attempt's hints.
    ///
    /// - Parameters:
    ///   - address: The expected EndpointID and reachability hints.
    ///   - alpn: The exact ALPN to negotiate.
    /// - Returns: The TLS-authenticated connection.
    /// - Throws: A transport error or `CancellationError`.
    func connect(
        to address: CmxIrohEndpointAddress,
        alpn: Data
    ) async throws -> any CmxIrohConnection

    /// Accepts the next connection that negotiated a configured ALPN.
    ///
    /// - Returns: The accepted connection, or `nil` after endpoint close.
    /// - Throws: A transport error for a failed handshake.
    func accept() async throws -> (any CmxIrohConnection)?

    /// Replaces relay credentials without changing the EndpointID.
    ///
    /// - Parameter relays: The new complete managed relay set.
    /// - Throws: A transport error when the update cannot be applied.
    func replaceRelays(_ relays: [CmxIrohRelayConfiguration]) async throws

    /// Emits network and unexpected-driver lifecycle signals.
    ///
    /// - Returns: A generation-scoped health stream that finishes on close.
    func healthEvents() async -> AsyncStream<CmxIrohEndpointHealthEvent>

    /// Returns whether the underlying endpoint driver can still serve this generation.
    ///
    /// This snapshot is used when an app returns to the foreground, where iOS
    /// may have suspended delivery of the driver's terminal event.
    func isHealthy() async -> Bool

    /// Closes the endpoint and cancels its network work.
    func close() async
}
