import Foundation

/// One GET to one checked address.
nonisolated struct RemoteImageRequest: Equatable, Sendable {
    let address: IPAddress
    /// The URL's host: the TLS server name and the `Host` header.
    let host: String
    let port: Int
    /// The path and query.
    let target: String
    let headers: [String: String]
}

nonisolated struct RemoteImageResponse: Equatable, Sendable {
    let status: Int
    /// Lowercased names.
    let headers: [String: String]
    let body: Data
}

/// Sends one request to its address and returns the answer, failing past `maximumBytes` of body.
protocol RemoteImageTransport: Sendable {
    func send(_ request: RemoteImageRequest, maximumBytes: Int) async throws -> RemoteImageResponse
}
