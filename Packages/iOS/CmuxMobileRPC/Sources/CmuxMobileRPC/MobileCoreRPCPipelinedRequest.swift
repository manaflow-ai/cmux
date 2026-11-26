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

    /// Releases the request's session settlement state without awaiting it.
    ///
    /// Callers that drop a handle before (or instead of) calling ``response()``
    /// must abandon it, or the session retains the settlement slot until the
    /// request deadline and, for an already-settled response, until teardown.
    public func abandon() async {
        await session.cancelPendingRequest(requestID: requestID)
    }
}
