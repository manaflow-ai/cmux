import CmuxLink
import Foundation

/// The acceptor's single-writer state: live transports, the latest
/// initiation timestamp per device key, and one reader per underlay.
actor AcceptorState {
    private let identity: WireGuardPrivateKey
    private let hostID: String
    private let authorizer: any WireGuardAuthorizer
    private let configuration: WireGuardLinkConfiguration
    private let clock: LinkClock
    private let source: WireGuardHandshakeSource
    private let sink: AsyncStream<any LinkTransport>.Continuation
    private let handshake: WireGuardHandshake
    private var live: [ObjectIdentifier: WireGuardLinkTransport] = [:]
    private var latestTimestamps: [WireGuardPublicKey: TAI64N] = [:]
    private var listenTask: Task<Void, Never>?
    private var readers: [UUID: Task<Void, Never>] = [:]
    private var stopped = false

    init(
        identity: WireGuardPrivateKey,
        hostID: String,
        authorizer: any WireGuardAuthorizer,
        configuration: WireGuardLinkConfiguration,
        clock: LinkClock,
        source: WireGuardHandshakeSource,
        sink: AsyncStream<any LinkTransport>.Continuation
    ) {
        self.identity = identity
        self.hostID = hostID
        self.authorizer = authorizer
        self.configuration = configuration
        self.clock = clock
        self.source = source
        self.sink = sink
        handshake = WireGuardHandshake(identity: identity)
    }

    var liveCount: Int { live.count }

    func start(_ incoming: AsyncStream<any DatagramUnderlay>) {
        guard listenTask == nil, !stopped else { return }
        listenTask = Task { [weak self] in
            for await underlay in incoming {
                guard let self else { return }
                await self.read(underlay)
            }
        }
    }

    func stop() async {
        stopped = true
        listenTask?.cancel()
        sink.finish()
        // Transports close gracefully first: their readers must stay up to
        // deliver the peer's acks and closeAck.
        let transports = Array(live.values)
        live.removeAll()
        for transport in transports { await transport.close() }
        for reader in readers.values { reader.cancel() }
        readers.removeAll()
    }

    /// One reader per underlay: classifies datagrams until one names a
    /// transport, then forwards every event to it.
    private func read(_ underlay: any DatagramUnderlay) {
        guard !stopped else {
            Task { await underlay.close() }
            return
        }
        let id = UUID()
        readers[id] = Task { [weak self] in
            var target: (transport: WireGuardLinkTransport, token: UInt64)?
            for await event in underlay.events {
                if let target {
                    await target.transport.underlayEvent(event, token: target.token)
                    continue
                }
                guard let self else { break }
                guard case let .datagram(data) = event else {
                    if case .closed = event { break }
                    continue
                }
                target = await self.classify(data, on: underlay)
            }
            await self?.readerEnded(id)
        }
    }

    private func readerEnded(_ id: UUID) {
        readers[id] = nil
    }

    /// An initiation from an authorized key starts a transport; a data packet
    /// for a live session moves that session onto this underlay.
    private func classify(_ data: Data, on underlay: any DatagramUnderlay) async -> (WireGuardLinkTransport, UInt64)? {
        let bytes = [UInt8](data)
        guard let type = bytes.first else { return nil }
        switch type {
        case WireGuardProtocol.initiationType:
            return await accept(bytes, on: underlay)
        case WireGuardProtocol.dataType where bytes.count >= WireGuardProtocol.minimumDataLength:
            let receiver = WireGuardProtocol.readLE32(bytes, at: 4)
            for transport in live.values where await transport.ownsIndex(receiver) {
                if let token = await transport.adopt(underlay, firstDatagram: data) { return (transport, token) }
            }
            return nil
        default:
            return nil
        }
    }

    private func accept(_ bytes: [UInt8], on underlay: any DatagramUnderlay) async -> (WireGuardLinkTransport, UInt64)? {
        guard let initiation = try? handshake.consumeInitiation(bytes) else { return nil }
        if let latest = latestTimestamps[initiation.peer], initiation.timestamp <= latest { return nil }
        guard let authorized = await authorizer.authorize(peer: initiation.peer), !stopped else { return nil }
        if let latest = latestTimestamps[initiation.peer], initiation.timestamp <= latest { return nil }
        latestTimestamps[initiation.peer] = initiation.timestamp

        let transport = WireGuardLinkTransport(
            tunnel: WireGuardTunnel(identity: identity, peer: initiation.peer, timers: configuration.timers, source: source),
            role: .host,
            localAddress: OverlayAddress(id: hostID),
            remoteAddress: OverlayAddress(id: authorized.installID),
            configuration: configuration,
            clock: clock,
            peerInstall: authorized.installID
        )
        live[ObjectIdentifier(transport)] = transport
        let sink = self.sink
        await transport.setHooks(
            established: { transport in sink.yield(transport) },
            closed: { [weak self] transport in await self?.remove(transport) }
        )
        let token = await transport.attach(underlay, path: await underlay.path)
        await transport.startPump()
        await transport.answer(initiation)
        return (transport, token)
    }

    private func remove(_ transport: WireGuardLinkTransport) {
        live[ObjectIdentifier(transport)] = nil
    }
}
