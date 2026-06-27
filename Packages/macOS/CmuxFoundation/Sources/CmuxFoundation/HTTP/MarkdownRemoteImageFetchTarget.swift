public import Foundation
public import Network

/// A single pinned TLS endpoint to fetch a remote markdown image from.
///
/// ``MarkdownRemoteImageSecurity/pinnedFetchTargets(for:)`` resolves a safe
/// HTTPS image URL into one target per allowed resolved address. The connection
/// dials `endpointHost`:`port` directly while presenting and verifying
/// `serverName` (SNI + certificate hostname), so DNS rebinding cannot redirect
/// the fetch to a disallowed address after the safety check.
public struct MarkdownRemoteImageFetchTarget: Sendable {
    /// The original request URL, used to build the HTTP request line and Host header.
    public let url: URL
    /// The hostname presented for SNI and verified against the server certificate.
    public let serverName: String
    /// The concrete resolved address to dial, pinned ahead of the safety re-check.
    public let endpointHost: NWEndpoint.Host
    /// The TLS port to connect to (always 443 for allowed image fetches).
    public let port: UInt16

    /// Creates a pinned fetch target for `url` dialing `endpointHost`:`port`
    /// while presenting and verifying `serverName`.
    public init(url: URL, serverName: String, endpointHost: NWEndpoint.Host, port: UInt16) {
        self.url = url
        self.serverName = serverName
        self.endpointHost = endpointHost
        self.port = port
    }
}
