@testable import CmuxLinkWG
import Foundation

/// Two sans-IO tunnels and a manual notion of time, exchanging datagrams by
/// hand.
struct TunnelPair {
    let deviceKey = WireGuardPrivateKey()
    let hostKey = WireGuardPrivateKey()
    var device: WireGuardTunnel
    var host: WireGuardTunnel
    var now: Duration = .zero

    init(timers: WireGuardTimers = WireGuardTimers()) {
        device = WireGuardTunnel(identity: deviceKey, peer: hostKey.publicKey, timers: timers, source: WireGuardHandshakeSource())
        host = WireGuardTunnel(identity: hostKey, peer: deviceKey.publicKey, timers: timers, source: WireGuardHandshakeSource())
    }

    /// Device initiates; host answers; device confirms. Returns the
    /// device's datagrams sent after the response (keepalive or data).
    @discardableResult
    mutating func handshake() throws -> [[UInt8]] {
        let initiation = device.beginHandshake(now: now).datagrams
        precondition(initiation.count == 1)
        let response = respond(initiation[0])
        let confirm = device.decapsulate(response[0], now: now)
        precondition(confirm.sessionEstablished)
        for datagram in confirm.datagrams { _ = host.decapsulate(datagram, now: now) }
        return confirm.datagrams
    }

    mutating func respond(_ initiation: [UInt8]) -> [[UInt8]] {
        host.decapsulate(initiation, now: now).datagrams
    }
}
