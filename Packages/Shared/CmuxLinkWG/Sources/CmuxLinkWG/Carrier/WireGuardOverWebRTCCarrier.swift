public import CmuxLink

/// V2 dialer: opens a WebRTC underlay to the host, runs a WireGuard
/// handshake with the host key pinned at pairing, and returns a transport
/// whose lanes ride inside the tunnel.
public final class WireGuardOverWebRTCCarrier: LinkCarrier {
    public let kind = CarrierKind.webrtcWireGuard
    public let candidatePaths: [PathKind] = [.p2p, .turn]

    private let identity: WireGuardPrivateKey
    private let installID: String
    private let underlays: any DatagramUnderlayDialer
    private let hostKeys: any WireGuardHostKeyResolver
    private let configuration: WireGuardLinkConfiguration
    private let clock: LinkClock
    private let source: WireGuardHandshakeSource

    /// - Parameters:
    ///   - identity: the install's WireGuard key.
    ///   - installID: names this device's overlay address.
    public init(
        identity: WireGuardPrivateKey,
        installID: String,
        underlays: any DatagramUnderlayDialer,
        hostKeys: any WireGuardHostKeyResolver = WireGuardHintsResolver(),
        configuration: WireGuardLinkConfiguration = WireGuardLinkConfiguration(),
        clock: LinkClock = .continuous,
        source: WireGuardHandshakeSource = WireGuardHandshakeSource()
    ) {
        self.identity = identity
        self.installID = installID
        self.underlays = underlays
        self.hostKeys = hostKeys
        self.configuration = configuration
        self.clock = clock
        self.source = source
    }

    public func connect(to peer: LinkPeer) async throws -> any LinkTransport {
        try await connectTransport(to: peer)
    }

    /// `connect` with the concrete type (tests read the session index).
    public func connectTransport(to peer: LinkPeer) async throws -> WireGuardLinkTransport {
        guard let hostKey = await hostKeys.hostKey(for: peer) else {
            throw WireGuardCarrierError.missingHostKey(hostID: peer.hostID)
        }
        let underlay = try await underlays.open(to: peer)
        let transport = WireGuardLinkTransport(
            tunnel: WireGuardTunnel(identity: identity, peer: hostKey, timers: configuration.timers, source: source),
            role: .dialer(underlays: underlays, peer: peer),
            localAddress: OverlayAddress(id: installID),
            remoteAddress: OverlayAddress(id: peer.hostID),
            configuration: configuration,
            clock: clock
        )
        await transport.attachAndRead(underlay)
        await transport.startPump()
        do {
            try await transport.connect()
        } catch {
            await transport.close()
            throw error
        }
        return transport
    }
}
