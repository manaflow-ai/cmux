/// Sends one request to its checked address and returns the answer, failing past
/// `maximumBytes` of body. It never resolves a name: the address is the one the fetch checked.
public protocol RemoteFetchTransport: Sendable {
    func send(_ request: RemoteFetchRequest, maximumBytes: Int) async throws -> RemoteFetchResponse
}

/// A transport's connection failed before it was ready (no route, refused, TLS trust): no byte of
/// the request was sent, so ``GuardedRemoteFetch`` may try the host's next checked address.
public nonisolated struct RemoteFetchConnectFailure: Error {
    public let underlying: any Error

    public init(underlying: any Error) {
        self.underlying = underlying
    }
}
