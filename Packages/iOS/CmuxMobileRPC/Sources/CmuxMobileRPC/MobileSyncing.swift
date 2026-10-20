public import Foundation

/// The mobile-sync RPC seam: a persistent, multiplexed request/response and
/// server-pushed-event channel to one paired Mac.
///
/// ``MobileCoreRPCClient`` is the production conformer. Higher layers depend on
/// `any MobileSyncing` so the concrete client can be replaced with a double in
/// tests, and so the store can be rewired off the concrete in a later wave.
public protocol MobileSyncing: Sendable {
    /// Tear down the persistent transport (sign-out or client replacement).
    func disconnect() async

    /// Subscribe to server-pushed events for the given topics.
    /// - Parameter topics: Topics to receive; cancel by terminating iteration.
    /// - Returns: A stream of matching event envelopes.
    func subscribe(to topics: Set<String>) async -> AsyncStream<MobileEventEnvelope>

    /// Send one RPC request and await its response, multiplexed over the
    /// persistent transport.
    /// - Parameters:
    ///   - requestData: The JSON-encoded request frame.
    ///   - timeoutNanoseconds: Optional per-request override of the runtime deadline.
    /// - Returns: The raw JSON result payload.
    /// - Throws: ``MobileShellConnectionError`` on failure or timeout.
    func sendRequest(_ requestData: Data, timeoutNanoseconds: UInt64?) async throws -> Data
}
