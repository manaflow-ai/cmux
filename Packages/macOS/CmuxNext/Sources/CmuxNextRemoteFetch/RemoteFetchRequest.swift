/// One GET to one checked address.
public nonisolated struct RemoteFetchRequest: Equatable, Sendable {
    public let address: RemoteAddress
    /// The URL's host: the TLS server name and the `Host` header.
    public let host: String
    public let port: Int
    /// The path and query.
    public let target: String
    public let headers: [String: String]

    public init(address: RemoteAddress, host: String, port: Int, target: String, headers: [String: String]) {
        self.address = address
        self.host = host
        self.port = port
        self.target = target
        self.headers = headers
    }
}
