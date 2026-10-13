public import CmuxWireGuardPairing
public import Foundation

/// The phone's side of the overlay: one tunnel to one paired Mac.
///
/// The phone is the WireGuard initiator. A Mac may be reachable at several
/// endpoints (LAN, tailnet, IPv6); the link tries each in turn, best known
/// first, until a tunneled TCP connection opens, and remembers the winner.
public final class PairedHostLink: @unchecked Sendable {
    public let host: PairedHost
    private let tunnel: WireGuardTunnel
    private let lock = NSLock()
    private var endpoint: String?

    public init(host: PairedHost, privateKey: WireGuardKey) throws {
        self.host = host
        tunnel = try WireGuardTunnel(address: host.address, privateKey: privateKey, peers: [
            .init(publicKey: host.hostKey, presharedKey: host.presharedKey, endpoint: host.endpointsToTry.first,
                  allowedIPs: ["\(host.hostAddress)/32"], keepaliveSeconds: 25),
        ])
        endpoint = host.endpointsToTry.first
    }

    deinit { tunnel.stop() }

    /// The endpoint the last successful connection used.
    public var currentEndpoint: String? { lock.withLock { endpoint } }

    /// Opens a tunneled connection to the Mac's `port`, trying each endpoint
    /// for `perEndpoint`.
    public func connect(port: UInt16, perEndpoint: Duration = .seconds(4)) async throws -> SocketStream {
        // The endpoint that worked last is tried first, and once more at the end.
        var order = host.endpointsToTry
        if let current = currentEndpoint {
            order = [current] + order.filter { $0 != current }
        }
        for candidate in order {
            if candidate != currentEndpoint {
                try tunnel.setEndpoint(candidate, for: host.hostKey)
                lock.withLock { endpoint = candidate }
            }
            if let stream = try? await tunnel.connect(host: host.hostAddress, port: port, timeout: perEndpoint) {
                return stream
            }
        }
        throw PairingError.unreachable
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
        while !buffer.contains(0x0A) {
            guard let chunk = try await stream.read(), buffer.count < 64 * 1024 else { throw PairingError.unreachable }
            buffer.append(chunk)
        }
        let line = buffer[buffer.startIndex..<buffer.firstIndex(of: 0x0A)!]
        let response = try JSONLine().decode(EnrollmentResponse.self, from: Data(line))
        var host = try PairedHost(invitation: invitation, response: response, pairedAt: now)
        host.lastGoodEndpoint = winner
        return host
    }
}
