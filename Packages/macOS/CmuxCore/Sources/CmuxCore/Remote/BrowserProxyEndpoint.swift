/// A loopback HTTP/SOCKS proxy endpoint the embedded browser routes through to
/// reach services on a remote workspace host.
///
/// Descriptions are redacted to host and port so the credential never
/// reaches logs or status payloads through interpolation.
public struct BrowserProxyEndpoint: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Proxy host, always a loopback address in practice.
    public let host: String
    /// Proxy TCP port.
    public let port: Int
    /// Credential the proxy requires on every SOCKS5 and HTTP CONNECT
    /// handshake; minted per tunnel start.
    public let credential: BrowserProxyCredential

    /// Creates an endpoint value.
    public init(host: String, port: Int, credential: BrowserProxyCredential) {
        self.host = host
        self.port = port
        self.credential = credential
    }

    /// Host and port only; the credential is never included.
    public var description: String { "BrowserProxyEndpoint(\(host):\(port))" }

    /// Redacted like ``description``.
    public var debugDescription: String { description }
}
