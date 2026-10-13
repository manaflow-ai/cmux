public import CmuxWireGuardPairing
public import Foundation
import os

/// The phone's side of the overlay: one tunnel to one paired Mac.
///
/// The phone is the WireGuard initiator. A Mac may be reachable at several
/// endpoints (LAN, tailnet, IPv6); the link tries each in turn, best known
/// first, until a tunneled TCP connection opens, and remembers the winner.
public final class PairedHostLink: Sendable {
    public let host: PairedHost
    private let tunnel: WireGuardTunnel
    private let endpoint: OSAllocatedUnfairLock<String?>

    public init(host: PairedHost, privateKey: WireGuardKey) throws {
        self.host = host
        tunnel = try WireGuardTunnel(address: host.address, privateKey: privateKey,
                                     peers: [Self.peer(for: host, endpoint: host.endpointsToTry.first)])
        endpoint = OSAllocatedUnfairLock(initialState: host.endpointsToTry.first)
    }

    deinit { tunnel.stop() }

    /// The endpoint the last successful connection used.
    public var currentEndpoint: String? { endpoint.withLock { $0 } }

    /// Opens a tunneled connection to the Mac's `port`. The current session
    /// is tried first; then each endpoint with a fresh session, so a Mac that
    /// restarted (and forgot the session) answers at once instead of after
    /// WireGuard's 15 s rekey timeout.
    public func connect(port: UInt16, perEndpoint: Duration = .seconds(4)) async throws -> SocketStream {
        // A live session answers within a round trip; don't wait long on a stale one.
        if let stream = try? await tunnel.connect(host: host.hostAddress, port: port, timeout: .milliseconds(1500)) {
            return stream
        }
        var order = host.endpointsToTry
        if let current = currentEndpoint {
            order = [current] + order.filter { $0 != current }
        }
        for candidate in order {
            try resetPeer(endpoint: candidate)
            if let stream = try? await tunnel.connect(host: host.hostAddress, port: port, timeout: perEndpoint) {
                return stream
            }
        }
        throw PairingError.unreachable
    }

    /// Re-adds the Mac's peer at `endpoint`. Removing a peer drops its
    /// session keys, so the next packet starts a new handshake immediately.
    private func resetPeer(endpoint: String) throws {
        try tunnel.removePeer(host.hostKey)
        try tunnel.setPeer(Self.peer(for: host, endpoint: endpoint))
        self.endpoint.withLock { $0 = endpoint }
    }

    static func peer(for host: PairedHost, endpoint: String?) -> WireGuardTunnel.Peer {
        .init(publicKey: host.hostKey, presharedKey: host.presharedKey, endpoint: endpoint,
              allowedIPs: ["\(host.hostAddress)/32"], keepaliveSeconds: 25)
    }

    /// After a network change: reopen the UDP socket so the next handshake
    /// leaves on the new interface.
    public func networkChanged() {
        tunnel.rebind()
    }

    public func status() -> WireGuardStatus.PeerStatus? {
        tunnel.status().peer(host.hostKey)
    }

    public func close() {
        tunnel.stop()
    }
}

/// Pairs this phone with a Mac from a scanned invitation.
public struct WireGuardPairingClient: Sendable {
    public init() {}

    /// Uses the invitation's one-time identity to send `permanentKey`'s
    /// public half to the Mac, and returns the paired Mac to store.
    public func pair(invitation: PairingInvitation, permanentKey: WireGuardKey, deviceName: String,
                     deviceModel: String, plan: OverlayPlan = OverlayPlan(), now: Date = Date()) async throws -> PairedHost {
        guard now < invitation.expiry else { throw PairingError.expired }
        let tunnel = try WireGuardTunnel(address: invitation.bootstrapAddress, privateKey: invitation.bootstrapKey, peers: [
            .init(publicKey: invitation.hostKey, presharedKey: invitation.presharedKey,
                  endpoint: invitation.endpoints.first, allowedIPs: ["\(invitation.hostAddress)/32"]),
        ])
        defer { tunnel.stop() }
        var stream: SocketStream?
        var winner: String?
        for (index, candidate) in invitation.endpoints.enumerated() {
            if index > 0 { try tunnel.setEndpoint(candidate, for: invitation.hostKey) }
            if let opened = try? await tunnel.connect(host: invitation.hostAddress, port: plan.enrollmentPort,
                                                      timeout: .seconds(4)) {
                stream = opened
                winner = candidate
                break
            }
        }
        guard let stream else { throw PairingError.unreachable }
        defer { stream.close() }
        let request = EnrollmentRequest(publicKey: permanentKey.publicKey, deviceName: deviceName, deviceModel: deviceModel)
        try await stream.write(JSONLine().encode(request))
        var buffer = Data()
        var newline = buffer.firstIndex(of: 0x0A)
        while newline == nil {
            guard let chunk = try await stream.read(), buffer.count < 64 * 1024 else { throw PairingError.unreachable }
            buffer.append(chunk)
            newline = buffer.firstIndex(of: 0x0A)
        }
        let response = try JSONLine().decode(EnrollmentResponse.self, from: Data(buffer.prefix { $0 != 0x0A }))
        var host = try PairedHost(invitation: invitation, response: response, pairedAt: now)
        host.lastGoodEndpoint = winner
        return host
    }
}
