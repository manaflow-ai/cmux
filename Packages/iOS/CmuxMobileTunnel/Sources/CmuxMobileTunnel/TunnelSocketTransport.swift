import Foundation
import NIOCore

/// The phone's TCP sockets: loopback listeners for the SOCKS proxy and port
/// forwards, and outbound connections (direct tunnels, SSH).
///
/// One interface with a per-platform implementation, the way Chromium's
/// `net/socket/tcp_socket.h` fronts `tcp_socket_posix.cc` and
/// `tcp_socket_win.cc`. Apple platforms use Network.framework through
/// NIOTransportServices, so iOS path changes surface as connection closure
/// rather than silent stalls (`TunnelSocketTransport+NetworkFramework.swift`).
/// Other platforms (Linux, where these packages' tests also run) use NIOPosix
/// sockets (`TunnelSocketTransport+POSIX.swift`).
///
/// Both implementations provide:
/// - `nextEventLoop()`: a loop of the group the transport's channels run on.
/// - `listenOnLoopback(port:childChannelInitializer:)`: binds `127.0.0.1:port`
///   (`0` picks a free port); accepted channels allow remote half-close and
///   start with `autoRead` off, so no byte arrives before their owner reads.
/// - `connect(host:port:timeout:eventLoop:relay:channelInitializer:)`: opens
///   a TCP connection; `relay` sets the accepted-channel options above for a
///   stream a `NIOChannelByteStream` will own.
/// - `openError(_:)`: the `TunnelOpenError` a platform connect error means.
public struct TunnelSocketTransport: Sendable {
    public init() {}
}

extension TunnelOpenError {
    /// The tunnel failure a connect's POSIX error code means.
    init(connectFailure code: POSIXErrorCode) {
        switch code {
        case .ECONNREFUSED: self = .connectionRefused
        case .EHOSTUNREACH, .EHOSTDOWN: self = .hostUnreachable
        case .ENETUNREACH, .ENETDOWN: self = .networkUnreachable
        case .ETIMEDOUT: self = .timedOut
        default: self = .generalFailure
        }
    }
}
