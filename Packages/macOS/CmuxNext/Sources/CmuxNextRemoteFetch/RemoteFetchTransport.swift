/// Sends one request to its checked address and returns the answer, failing past
/// `maximumBytes` of body unless the request explicitly allows an identity-encoded prefix, which
/// stops at that cap. It never resolves a name: the address is the one the fetch checked.
public protocol RemoteFetchTransport: Sendable {
    func send(_ request: RemoteFetchRequest, maximumBytes: Int) async throws -> RemoteFetchResponse
}
