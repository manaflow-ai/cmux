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
        // Every saved address is stale: look for the Mac on this network.
        for candidate in await WireGuardHostDiscovery().endpoints(hostID: host.hostID) where !order.contains(candidate) {
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
    /// Pairs with the Mac on this network whose current code is `code`. Each
    /// Mac found is tried with the invitation the code derives for its key;
    /// only the Mac that minted the code answers the handshake.
    public func pair(code: PairingCode, permanentKey: WireGuardKey, deviceName: String,
                     deviceModel: String, now: Date = Date()) async throws -> PairedHost {
        let hosts = await WireGuardHostDiscovery().hosts()
        guard !hosts.isEmpty else {
            throw PairingError.refused(String(localized: "No Mac running cmux was found on this network. Use the QR code instead."))
        }
        for host in hosts {
            guard let hostKey = host.hostKey else { continue }
            let invitation = PairingInvitation(code: code, hostName: host.name, hostID: host.hostID, hostKey: hostKey,
                                               endpoints: [host.endpoint], expiresAt: now.addingTimeInterval(60))
            if let paired = try? await pair(invitation: invitation, permanentKey: permanentKey, deviceName: deviceName,
                                            deviceModel: deviceModel, now: now, perEndpoint: .seconds(6)) {
                return paired
            }
        }
        throw PairingError.refused(String(localized: "That code didn't match a Mac on this network. Check it, or show a new one."))
    }

    public func pair(invitation: PairingInvitation, permanentKey: WireGuardKey, deviceName: String,
                     deviceModel: String, plan: OverlayPlan = OverlayPlan(), now: Date = Date(),
                     perEndpoint: Duration = .seconds(12)) async throws -> PairedHost {
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
            // Generous: the first LAN packet raises iOS's Local Network prompt,
            // and WireGuard retries its handshake every 5 s until it is answered.
            if let opened = try? await tunnel.connect(host: invitation.hostAddress, port: plan.enrollmentPort,
                                                      timeout: perEndpoint) {
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
        // Half-close and wait briefly for the Mac's close, so it can drop the
        // one-time peer at once rather than at its deadline.
        stream.shutdownWrite()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { while let chunk = try? await stream.read(), !chunk.isEmpty {} }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
            stream.close()
        }
        var host = try PairedHost(invitation: invitation, response: response, pairedAt: now)
        host.lastGoodEndpoint = winner
        return host
    }
}
