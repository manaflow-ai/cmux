public import CmuxMobileTunnel
import Foundation
import NIOCore

/// A SOCKS5 proxy on the phone's loopback whose every connection leaves from
/// the SSH server (`ssh -D`).
///
/// Each `CONNECT` becomes a `direct-tcpip` channel to the requested host and
/// port (``SSHDirectTCPIPBackend``), and a domain-name address is resolved by
/// the server. A browser using this proxy therefore sees the server's
/// network: its `localhost`, every port on it, and names only the server can
/// resolve, with the page's own origin unchanged. The SOCKS protocol and the
/// relay are the transport-agnostic ``SocksProxyServer``.
public final class SSHSocksProxy: Sendable {
    /// The bound loopback port.
    public var port: Int { server.port }
    private let server: SocksProxyServer

    private init(server: SocksProxyServer) {
        self.server = server
    }

    /// Starts the proxy on `127.0.0.1:<port>` (`0` picks a free port).
    /// `onConnect` observes each accepted request (host as sent, port).
    public static func start(
        over connection: SSHConnection,
        port: Int = 0,
        onConnect: (@Sendable (String, Int) -> Void)? = nil
    ) async throws -> SSHSocksProxy {
        let server = try await SocksProxyServer.start(
            backend: SSHDirectTCPIPBackend(connection: connection),
            port: port,
            onConnect: onConnect
        )
        return SSHSocksProxy(server: server)
    }

    /// Stops accepting connections and aborts open tunnels.
    public func stop() async {
        await server.stop()
    }
}

/// Opens tunnel connections as SSH `direct-tcpip` channels: the connection
/// leaves from the SSH server, which also resolves host names.
public struct SSHDirectTCPIPBackend: SocksConnectBackend {
    public let connection: SSHConnection

    public init(connection: SSHConnection) {
        self.connection = connection
    }

    public func open(host: String, port: Int) async throws -> any TunnelByteStream {
        let installed = InstalledStream()
        do {
            _ = try await connection.openDirectTCPIP(host: host, port: port) { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(SSHChannelDataUnwrapper())
                    // Pulled reads: the SSH window, not memory, holds what the
                    // browser has not read yet.
                    try child.syncOptions?.setOption(ChannelOptions.autoRead, value: false)
                    installed.stream = try NIOChannelByteStream.installSync(on: child)
                }
            }
        } catch {
            throw Self.openError(error)
        }
        guard let stream = installed.stream else { throw TunnelOpenError.generalFailure }
        return stream
    }

    /// OpenSSH reports every connect failure (refused, unreachable,
    /// unresolvable) as `SSH_OPEN_CONNECT_FAILED` (2) and a forbidden forward
    /// as `SSH_OPEN_ADMINISTRATIVELY_PROHIBITED` (1).
    static func openError(_ error: any Error) -> TunnelOpenError {
        let text = String(describing: error)
        if text.contains("Reason: 1 ") || text.hasSuffix("Reason: 1") { return .notAllowed }
        if text.contains("Reason: 2 ") || text.hasSuffix("Reason: 2") { return .connectionRefused }
        return .hostUnreachable
    }

    private final class InstalledStream: @unchecked Sendable {
        var stream: NIOChannelByteStream?
    }
}
