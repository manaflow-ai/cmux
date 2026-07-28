public import Foundation

/// A request already enqueued on a ``MobileCoreRPCClient`` ordered transport.
public struct MobileCoreRPCPipelinedRequest: Sendable {
    let requestID: String
    let session: MobileCoreRPCSession

    /// Waits for the enqueued request's response, timeout, or connection failure.
    ///
    /// - Returns: The decoded JSON-RPC result payload.
    /// - Throws: Cancellation or the request's terminal RPC/transport error.
    public func response() async throws -> Data {
        try await session.awaitResponse(requestID: requestID)
    }
}
