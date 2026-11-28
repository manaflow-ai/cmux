import Foundation

/// Why a tunnel did not open, as the proxy shows it.
public enum LoopbackTunnelFailure: Error, Sendable, Equatable {
    /// The machine's cmux-tui lacks `loopback-forward-v1`.
    case unsupported
    /// The machine turned forwarding off.
    case disabled
    /// The machine's port policy refuses the port.
    case portNotAllowed
    /// Nothing listens there.
    case refused
    /// Not connected to the machine.
    case unavailable(String)
    case other(String)
}

/// Opens tunnels to one machine.
public protocol LoopbackTunnelOpening: Sendable {
    func openTunnel(host: String, port: UInt16) async throws(LoopbackTunnelFailure) -> any LoopbackTunnel
}
