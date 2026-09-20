/// A loopback HTTP/SOCKS proxy endpoint the embedded browser routes through to
/// reach services on a remote workspace host. Every publisher (the
/// daemon-backed proxy and ssh-tmux's `RemoteTmuxBrowserProxyListener`) is a
/// full dual-protocol listener understanding both SOCKS5 and HTTP CONNECT, so
/// there is no bare-SOCKS5-only case to distinguish here.
public struct BrowserProxyEndpoint: Equatable, Sendable {
    /// Proxy host, always a loopback address in practice.
    public let host: String
    /// Proxy TCP port.
    public let port: Int

    /// Creates an endpoint value; mirrors the original memberwise initializer.
    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}
