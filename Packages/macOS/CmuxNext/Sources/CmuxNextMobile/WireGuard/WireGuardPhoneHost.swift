public import CmuxWireGuardPairing
public import Foundation
import CmuxNextWakeups
import CmuxWireGuard
import os

/// Phone access over an in-process WireGuard tunnel.
///
/// The Mac runs one userspace WireGuard device (no system VPN) at
/// `OverlayPlan.hostAddress`. Each paired phone is a peer with its own key,
/// preshared key and tunnel address; cryptokey routing makes a tunneled
/// connection's source address name the phone that sent it. Two tunnel
/// ports are served:
///
/// - daemon port: the phone's raw cmux-tui protocol, spliced to the local
///   daemon socket through `DaemonLanePolicy` (the same allowlist irx
///   phones get);
/// - enrollment port: reachable only from a one-time bootstrap peer that a
///   pairing invitation (QR code) created; it trades the bootstrap identity
///   for a permanent peer.
public actor WireGuardPhoneHost {
    /// What the pairing window shows.
    public struct Snapshot: Sendable, Equatable {
        public var running = false
        public var listenPort: UInt16?
        public var endpoints: [String] = []
        public var hostName = ""
        public var hostID = ""
        public var hostKeyFingerprint = ""
        public var phones: [WireGuardPairedPhone] = []
        /// Phone id -> open daemon connections.
        public var connections: [String: Int] = [:]
        /// Phone id -> last WireGuard handshake.
        public var lastHandshake: [String: Date] = [:]
        public var failure: String?
        /// Set once, when a phone completes pairing with the current invitation.
        public var justPaired: WireGuardPairedPhone?
    }

    public typealias SocketPath = @Sendable () async -> String?

    let plan = OverlayPlan()
    let store: WireGuardHostStore
    let hostName: String
    let daemonSocketPath: SocketPath
    let onChange: @Sendable (Snapshot) -> Void
    let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "mobile.wireguard")

    var state: WireGuardHostState?
    var tunnel: WireGuardTunnel?
    var listeners: [WireGuardListener] = []
    var invitation: PendingInvitation?
    let invitationExpiry = DemandTimer(owner: "mobile.wireguard.invitation")
    var connections: [String: Int] = [:]
    var failure: String?
    var justPaired: WireGuardPairedPhone?

    struct PendingInvitation: Sendable {
        let invitation: PairingInvitation
        let bootstrapPublicKey: WireGuardKey
    }

    public init(stateDirectory: URL, hostName: String, daemonSocketPath: @escaping SocketPath,
                onChange: @escaping @Sendable (Snapshot) -> Void) {
        store = WireGuardHostStore(stateDirectory: stateDirectory)
        self.hostName = hostName
        self.daemonSocketPath = daemonSocketPath
        self.onChange = onChange
    }

    /// Starts the device and both listeners. Safe to call again after stop.
    public func start() {
        guard tunnel == nil else { return }
        do {
            var state = try store.load()
            let peers = state.phones.map(Self.peer(for:))
            let tunnel: WireGuardTunnel
            do {
                tunnel = try WireGuardTunnel(address: plan.hostAddress, privateKey: state.privateKey,
                                             listenPort: state.listenPort ?? plan.preferredListenPort, peers: peers)
            } catch {
                // The port is taken (another cmux build on this Mac): any free port.
                logger.info("wireguard: preferred port busy, choosing another")
                tunnel = try WireGuardTunnel(address: plan.hostAddress, privateKey: state.privateKey, peers: peers)
            }
            let port = tunnel.status().listenPort
            if port != state.listenPort {
                state.listenPort = port
                try store.save(state)
            }
            self.state = state
            self.tunnel = tunnel
            let daemon = try tunnel.listen(port: plan.daemonPort)
            let enrollment = try tunnel.listen(port: plan.enrollmentPort)
            listeners = [daemon, enrollment]
            failure = nil
            // task-owner: accept loops end when stop() closes their listeners
            Task { await self.acceptLoop(daemon, serve: { await self.serveDaemon($0, from: $1) }) }
            // task-owner: accept loop; ends when stop() closes the enrollment listener
            Task { await self.acceptLoop(enrollment, serve: { await self.serveEnrollment($0, from: $1) }) }
            logger.info("wireguard: listening on UDP \(port.map(String.init) ?? "?", privacy: .public)")
        } catch {
            failure = error.localizedDescription
            logger.error("wireguard: start failed: \(String(describing: error), privacy: .public)")
        }
        publish()
    }

    public func stop() {
        invitationExpiry.cancel()
        invitation = nil
        for listener in listeners { listener.close() }
        listeners = []
        tunnel?.stop()
        tunnel = nil
        connections = [:]
        publish()
    }

    /// A fresh invitation for the QR code. It replaces the previous one and
    /// stays valid for `lifetime` or until one phone uses it.
    public func makeInvitation(lifetime: Duration = .seconds(600)) throws -> PairingInvitation {
        guard let tunnel, let state else { throw PairingError.unreachable }
        dropInvitation()
        let bootstrap = WireGuardKey()
        let psk = WireGuardKey(randomPresharedKey: ())
        let index = Int.random(in: 1...254)
        guard let address = plan.bootstrapAddress(index) else { throw PairingError.unreachable }
        try tunnel.setPeer(.init(publicKey: bootstrap.publicKey, presharedKey: psk, allowedIPs: ["\(address)/32"]))
        let port = tunnel.status().listenPort ?? plan.preferredListenPort
        let invitation = PairingInvitation(
            hostName: hostName, hostID: state.hostID, hostKey: state.privateKey.publicKey,
            endpoints: WireGuardEndpoints(port: port).candidates(), bootstrapKey: bootstrap,
            bootstrapAddress: address, presharedKey: psk, hostAddress: plan.hostAddress,
            expiresAt: Date().addingTimeInterval(TimeInterval(lifetime.components.seconds)))
        self.invitation = PendingInvitation(invitation: invitation, bootstrapPublicKey: bootstrap.publicKey)
        justPaired = nil
        invitationExpiry.schedule(after: lifetime) { [weak self] in await self?.dropInvitation() }
        publish()
        return invitation
    }

    /// Forgets the current invitation and its bootstrap peer.
    public func cancelInvitation() {
        invitationExpiry.cancel()
        dropInvitation()
        publish()
    }

    func dropInvitation() {
        guard let pending = invitation else { return }
        invitation = nil
        try? tunnel?.removePeer(pending.bootstrapPublicKey)
    }

    /// Unpairs a phone: its peer is removed at once, so open connections die.
    public func revoke(phoneID: String) throws {
        guard var state, let index = state.phones.firstIndex(where: { $0.id == phoneID }) else { return }
        let phone = state.phones.remove(at: index)
        try tunnel?.removePeer(phone.publicKey)
        try store.save(state)
        self.state = state
        publish()
    }

    public func snapshot() -> Snapshot {
        var snapshot = Snapshot()
        snapshot.running = tunnel != nil
        snapshot.hostName = hostName
        snapshot.failure = failure
        snapshot.justPaired = justPaired
        snapshot.connections = connections
        if let state {
            snapshot.hostKeyFingerprint = state.privateKey.publicKey.fingerprint
            snapshot.hostID = state.hostID
            snapshot.phones = state.phones
        }
        if let tunnel {
            let status = tunnel.status()
            snapshot.listenPort = status.listenPort
            snapshot.endpoints = status.listenPort.map { WireGuardEndpoints(port: $0).candidates() } ?? []
            for phone in snapshot.phones {
                if let handshake = status.peer(phone.publicKey)?.lastHandshake {
                    snapshot.lastHandshake[phone.id] = handshake
                }
            }
        }
        return snapshot
    }

    func publish() {
        onChange(snapshot())
    }

    static func peer(for phone: WireGuardPairedPhone) -> WireGuardTunnel.Peer {
        .init(publicKey: phone.publicKey, presharedKey: phone.presharedKey, allowedIPs: ["\(phone.address)/32"])
    }

    private func acceptLoop(_ listener: WireGuardListener,
                            serve: @escaping @Sendable (SocketStream, String) async -> Void) async {
        // wakeup-allow: awaits the next tunneled connection; ends when stop() closes the listener
        while let (stream, peer) = try? await listener.accept() {
            // task-owner: one tunneled connection; ends when either side closes
            Task { await serve(stream, peer) }
        }
    }

    /// A paired phone's daemon lane.
    func serveDaemon(_ stream: SocketStream, from address: String) async {
        guard plan.isDeviceAddress(address), let phone = state?.phones.first(where: { $0.address == address }) else {
            stream.close()
            return
        }
        guard let path = await daemonSocketPath(), let daemon = try? await UnixSocketLane.connect(path: path) else {
            logger.error("wireguard: no daemon socket for \(phone.name, privacy: .public)")
            stream.close()
            return
        }
        connections[phone.id, default: 0] += 1
        publish()
        let splice = DaemonLaneSplice(phone: SocketStreamLane(stream: stream), daemon: daemon,
                                      policy: DaemonLanePolicy(deviceID: phone.id))
        let reason = await splice.run()
        logger.info("wireguard: \(phone.name, privacy: .public) lane ended: \(String(describing: reason), privacy: .public)")
        connections[phone.id, default: 1] -= 1
        if connections[phone.id] == 0 { connections[phone.id] = nil }
        publish()
    }
}
