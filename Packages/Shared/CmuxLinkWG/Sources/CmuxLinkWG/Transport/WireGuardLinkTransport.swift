public import CmuxLink
import Foundation

/// One V2 transport: a WireGuard session with one peer over a replaceable
/// `DatagramUnderlay`, carrying A3's lanes as reliable or unreliable
/// fragments inside overlay UDP datagrams (b3-webrtc-wg.md sections 5, 6).
public actor WireGuardLinkTransport: LinkTransport {
    public nonisolated let capabilities: TransportCapabilities
    public nonisolated let events: AsyncStream<TransportEvent>
    /// The peer's authenticated WireGuard key.
    public nonisolated let remoteKey: WireGuardPublicKey
    /// The WireGuard static key the handshake proved; on the host also the
    /// install the authorizer resolved it to (B5 `CarrierAttestation`).
    public nonisolated let peerIdentity: LinkPeerIdentity?

    let eventSink: AsyncStream<TransportEvent>.Continuation
    let role: TransportRole
    let configuration: WireGuardLinkConfiguration
    let clock: LinkClock
    let localAddress: OverlayAddress
    let remoteAddress: OverlayAddress
    var tunnel: WireGuardTunnel
    var phase: TransportPhase = .handshaking

    // Underlay
    var underlay: (any DatagramUnderlay)?
    var underlayToken: UInt64 = 0
    var currentPath: PathKind = .p2p
    var maxDatagramBytes = 1200
    var readerTask: Task<Void, Never>?
    var rebindTask: Task<Void, Never>?
    var rebindDeadline: Duration?

    // Lanes
    var senders: [LaneID: ReliableSender] = [:]
    var receivers: [LaneID: ReliableReceiver] = [:]
    var reassemblers: [LaneID: MessageReassembler] = [:]
    var messageIDs: [LaneID: UInt32] = [:]
    var retransmit: RetransmitTimer
    var reportedRTT: Duration?

    // Send queues, drained by one pump in priority order.
    var rawQueue = LaneFIFO<[UInt8]>()
    var controlQueue = LaneFIFO<LaneFrame>()
    var ackDirty: Set<LaneID> = []
    var reliableQueues: [LaneID: LaneFIFO<UInt32>] = [:]
    var messageQueues: [LaneID: LaneFIFO<QueuedMessage>] = [:]
    var pumpTask: Task<Void, Never>?
    var pumpWaiter: CheckedContinuation<Void, Never>?

    // Waiters
    var nextWaiterID: UInt64 = 0
    var windowWaiters: [UInt64: (lane: LaneID, continuation: CheckedContinuation<Void, any Error>)] = [:]
    var handshakeWaiter: CheckedContinuation<Void, any Error>?
    var drainWaiter: CheckedContinuation<Void, Never>?
    var closedWaiters: [CheckedContinuation<Void, Never>] = []

    // Timers
    var connectDeadline: Duration?
    var closeDeadline: Duration?
    var closeSentAt: Duration?
    var timerTask: Task<Void, Never>?
    var armedDeadline: Duration?

    // Acceptor hooks
    var onEstablished: (@Sendable (WireGuardLinkTransport) async -> Void)?
    var onClosed: (@Sendable (WireGuardLinkTransport) async -> Void)?

    init(
        tunnel: WireGuardTunnel,
        role: TransportRole,
        localAddress: OverlayAddress,
        remoteAddress: OverlayAddress,
        configuration: WireGuardLinkConfiguration,
        clock: LinkClock,
        peerInstall: String? = nil
    ) {
        self.tunnel = tunnel
        self.role = role
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.configuration = configuration
        self.clock = clock
        remoteKey = tunnel.peer
        peerIdentity = LinkPeerIdentity(carrier: .webrtcWireGuard, keyKind: .x25519,
                                        publicKey: tunnel.peer.rawRepresentation, install: peerInstall)
        capabilities = TransportCapabilities(maxFrameBytes: configuration.maxFrameBytes, carriesBulk: true, carriesMedia: false)
        retransmit = RetransmitTimer(
            minimum: configuration.minimumRetransmitTimeout, maximum: configuration.maximumRetransmitTimeout
        )
        (events, eventSink) = AsyncStream.makeStream(of: TransportEvent.self, bufferingPolicy: .unbounded)
    }

    public var path: LinkPath {
        LinkPath(kind: currentPath, carrier: .webrtcWireGuard)
    }

    /// The local WireGuard index of the current keypair (tests: a rekey or a
    /// re-handshake changes it, a roam does not).
    public var currentSessionIndex: UInt32? { tunnel.currentLocalIndex }

    func setHooks(
        established: (@Sendable (WireGuardLinkTransport) async -> Void)?,
        closed: (@Sendable (WireGuardLinkTransport) async -> Void)?
    ) {
        onEstablished = established
        onClosed = closed
    }

    func startPump() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in await self?.runPump() }
    }

    // MARK: LinkTransport

    public func send(_ frame: TransportFrame) async throws {
        try Task.checkCancellation()
        guard phase == .open else { throw WireGuardCarrierError.closed }
        guard frame.bytes.count <= capabilities.maxFrameBytes else {
            throw LinkError.messageTooLarge(size: frame.bytes.count, limit: capabilities.maxFrameBytes)
        }
        let lane = LaneID(frame.lane)
        switch lane.kind {
        case .reliable:
            try await waitForWindow(lane, adding: frame.bytes.count)
            guard phase == .open else { throw WireGuardCarrierError.closed }
            var sender = senders[lane] ?? ReliableSender(lane: lane)
            let seqs = sender.enqueue([UInt8](frame.bytes), maxPayload: maxReliablePayload)
            senders[lane] = sender
            var queue = reliableQueues[lane] ?? LaneFIFO()
            for seq in seqs { queue.push(seq) }
            reliableQueues[lane] = queue
        case .unordered, .partial:
            enqueueMessage(frame, lane: lane)
        }
        wakePump()
        rearmTimer()
    }

    public func publishMediaTrack(_ descriptor: MediaTrackDescriptor) async throws -> MediaTrackHandle {
        throw WireGuardCarrierError.mediaUnsupported
    }

    // MARK: Sizes

    /// Plaintext budget of one WireGuard datagram: header and tag off, then
    /// rounded down to WireGuard's 16-byte padding.
    var maxPlaintext: Int {
        (maxDatagramBytes - WireGuardProtocol.minimumDataLength) / 16 * 16
    }

    var maxReliablePayload: Int {
        max(1, maxPlaintext - OverlayDatagram.headerLength - LaneFrame.reliableHeaderLength)
    }

    var maxMessagePayload: Int {
        max(1, maxPlaintext - OverlayDatagram.headerLength - LaneFrame.messageHeaderLength)
    }

    var receiveWindowFragments: UInt32 {
        UInt32(max(256, configuration.reliableWindowBytes / max(1, maxReliablePayload) * 2))
    }

    // MARK: Helpers

    func emit(_ event: TransportEvent) {
        guard phase != .closed else { return }
        eventSink.yield(event)
    }

    func transportLane(_ lane: LaneID, lifetimeMillis: UInt32 = 0) -> TransportLane {
        switch lane.kind {
        case .reliable: TransportLane(reliability: .reliableOrdered, priority: lane.priority)
        case .unordered: TransportLane(reliability: .unreliableUnordered, priority: lane.priority)
        case .partial: TransportLane(reliability: .partial(maxLifetime: .milliseconds(lifetimeMillis)), priority: lane.priority)
        }
    }

    private func enqueueMessage(_ frame: TransportFrame, lane: LaneID) {
        let bytes = [UInt8](frame.bytes)
        let id = messageIDs[lane, default: 0]
        messageIDs[lane] = id &+ 1
        var lifetime: Duration?
        var lifetimeMillis: UInt32 = 0
        if case let .partial(maxLifetime) = frame.lane.reliability {
            lifetime = maxLifetime
            let millis = maxLifetime.components.seconds * 1000 + maxLifetime.components.attoseconds / 1_000_000_000_000_000
            lifetimeMillis = UInt32(clamping: millis)
        }
        let payload = maxMessagePayload
        let count = max(1, (bytes.count + payload - 1) / payload)
        guard count <= Int(UInt16.max) else { return }
        var queue = messageQueues[lane] ?? LaneFIFO()
        let now = clock.now
        for index in 0..<count {
            let start = index * payload
            let end = min(bytes.count, start + payload)
            let encoded = LaneFrame.message(
                lane: lane, id: id, index: UInt16(index), count: UInt16(count), lifetimeMillis: lifetimeMillis,
                payload: start < end ? Array(bytes[start..<end]) : []
            ).encode()
            queue.push(QueuedMessage(frame: encoded, enqueuedAt: now, lifetime: lifetime))
        }
        // Media semantics: a full queue drops its oldest datagrams.
        while queue.count > configuration.messageQueueLimit { _ = queue.pop() }
        messageQueues[lane] = queue
    }
}
