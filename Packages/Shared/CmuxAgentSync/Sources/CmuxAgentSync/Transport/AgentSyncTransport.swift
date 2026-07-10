public import Foundation

/// Abstract request/response and server-pushed-event transport for agent GUI sync.
public protocol AgentSyncTransport: Sendable {
    /// Stream of connection edges emitted by the transport.
    var connectionEvents: AsyncStream<AgentSyncConnectionEvent> { get }

    /// Sends a raw JSON request to the Mac and returns the raw JSON result.
    /// - Parameters:
    ///   - method: The `gui.v1` RPC method name.
    ///   - params: Raw JSON request parameters.
    /// - Returns: Raw JSON response payload.
    /// - Throws: A transport or GUI wire error.
    func request(method: String, params: Data) async throws -> Data

    /// Subscribes to the requested event topics and returns matching raw frames.
    /// - Parameter topics: Event topics to subscribe to.
    /// - Returns: A stream of raw frames for the requested topics.
    /// - Throws: A transport or GUI wire error.
    func subscribe(topics: [String]) async throws -> AsyncStream<AgentSyncFrame>

    /// Unsubscribes from event topics that are no longer needed.
    /// - Parameter topics: Event topics to unsubscribe from.
    func unsubscribe(topics: [String]) async
}
