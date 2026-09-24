public import CMUXMobileCore
public import Foundation

/// One TCP connection opened FROM the paired Mac for the phone's "On iPhone"
/// browser: raw bytes both ways on a dedicated lane of the admitted
/// connection. Byte-level on purpose, so this package stays free of the
/// SOCKS and NIO plumbing that sits on top of it.
public protocol MobileTunnelLaneConnection: Sendable {
    /// The next chunk, or nil once the Mac side finished sending.
    func receive(maximumByteCount: Int) async throws -> Data?
    func send(_ data: Data) async throws
    /// Half-close our sending side.
    func finishSending() async
    /// Abort both directions.
    func close() async
}

/// Why the Mac did not open a tunnel connection.
public enum MobileTunnelOpenFailure: Error, Equatable, Sendable {
    /// The Mac's destination policy refused it.
    case denied
    case refused
    case hostUnreachable
    case networkUnreachable
    case timedOut
    case unresolved
    /// Too many tunnels, or opened too fast.
    case busy
    /// No usable connection to that Mac, or an unexpected failure.
    case unavailable
}

/// The Mac's loopback listeners and its tunnel policy.
public struct MobileTunnelListeningPorts: Equatable, Sendable {
    /// Port to the address to connect to on the Mac (`127.0.0.1` or `::1`).
    public var ports: [Int: String]
    /// Whether the Mac serves hosts other than its own loopback. When false
    /// the phone connects to those hosts itself.
    public var allowsNonLoopbackHosts: Bool

    public init(ports: [Int: String], allowsNonLoopbackHosts: Bool) {
        self.ports = ports
        self.allowsNonLoopbackHosts = allowsNonLoopbackHosts
    }
}

/// Opens a tunnel connection from the paired Mac to `host:port`.
public typealias MobileTunnelConnectProvider = @Sendable (
    _ request: CmxByteTransportRequest,
    _ host: String,
    _ port: Int
) async throws -> any MobileTunnelLaneConnection

/// Lists the paired Mac's loopback listening ports.
public typealias MobileTunnelListeningPortsProvider = @Sendable (
    _ request: CmxByteTransportRequest
) async throws -> MobileTunnelListeningPorts
