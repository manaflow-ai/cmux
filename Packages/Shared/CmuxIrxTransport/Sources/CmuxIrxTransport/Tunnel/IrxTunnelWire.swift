import Foundation

/// The phone browser tunnel: the phone's native browser reaches the network
/// through its paired Mac. The phone opens one `tcpConnect` lane per TCP
/// connection; the Mac decides (`IrxTunnelDestinationPolicy`), connects from
/// the Mac, and relays bytes. A `listeningPorts` lane lists the Mac's
/// loopback listeners so the phone can mirror them onto its own loopback,
/// because iOS never sends loopback destinations to a proxy.
public struct IrxTunnelCapability: Sendable {
    /// The capability this build speaks.
    public static let current = IrxTunnelCapability()

    /// Advertised in `mobile.host.status` by a Mac that serves both lanes.
    public let identifier: String

    public init(identifier: String = "browser.tunnel.v1") {
        self.identifier = identifier
    }
}

/// Mac -> phone, the first frame on a `tcpConnect` lane. After `connected`
/// the lane carries raw TCP bytes both ways; any other status ends the lane.
public struct IrxTunnelOpenReply: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case connected
        /// The Mac's destination policy refused the host or port.
        case denied
        case refused
        case hostUnreachable = "host_unreachable"
        case networkUnreachable = "network_unreachable"
        case timedOut = "timed_out"
        /// The host name did not resolve on the Mac.
        case unresolved
        /// Too many open tunnels, or opened too fast.
        case busy
        case failed
    }

    public var v: Int
    public var status: Status

    public init(status: Status) {
        v = IrxProtocol().version
        self.status = status
    }
}

/// One TCP listener on the Mac that loopback can reach.
public struct IrxListeningPort: Codable, Hashable, Sendable {
    public var port: Int
    /// The address to connect to: `127.x.y.z` or `::1` (a wildcard listener
    /// is reported as `127.0.0.1`, an IPv6-only wildcard as `::1`).
    public var address: String

    public init(port: Int, address: String) {
        self.port = port
        self.address = address
    }
}

/// Mac -> phone, the only frame on a `listeningPorts` lane.
public struct IrxListeningPortsReply: Codable, Equatable, Sendable {
    public var v: Int
    public var ports: [IrxListeningPort]
    /// Whether this Mac's policy lets the tunnel reach hosts other than its
    /// own loopback. When false the phone connects to those hosts itself.
    public var allowsNonLoopbackHosts: Bool

    public init(ports: [IrxListeningPort], allowsNonLoopbackHosts: Bool) {
        v = IrxProtocol().version
        self.ports = ports
        self.allowsNonLoopbackHosts = allowsNonLoopbackHosts
    }
}

/// A tunnel open the Mac did not complete.
public struct IrxTunnelOpenError: Error, Equatable, Sendable {
    public let status: IrxTunnelOpenReply.Status

    public init(status: IrxTunnelOpenReply.Status) {
        self.status = status
    }
}
