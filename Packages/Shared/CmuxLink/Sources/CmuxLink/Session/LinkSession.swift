public import Foundation

/// The implementation of `CmuxLink` (a3-link.md). One actor per link, on
/// both ends: the dialer (phone) races carriers and reconnects; the accepted
/// side (host, created by `LinkHost`) waits for the dialer to resume.
///
/// The session owns the connection state, channel revisions, retention of
/// unacknowledged reliable messages, credit, the priority send pump and path
/// migration. Carriers below it only move opaque frames on lanes.
public actor LinkSession: CmuxLink {
    enum Role: Sendable {
        case dialer(peer: LinkPeer, selector: PathSelector)
        case accepted(onClose: @Sendable (LinkSession) async -> Void)
    }

    struct Attached: Sendable {
        let generation: UInt64
        let transport: any LinkTransport
        var path: LinkPath
        let capabilities: TransportCapabilities
    }

    public nonisolated let sessionID: UUID
    let role: Role
    let configuration: LinkConfiguration
    let clock: LinkClock

    var machine = LinkStateMachine()
    var epoch: UInt64

    // Transports.
    var current: Attached?
    /// The authenticated peer of the first transport that carried a
    /// session (host) or of the current one (dialer).
    var authenticatedPeer: LinkPeerIdentity?
    /// Dialer: a transport that sent `hello` and waits for `welcome`.
    var pendingDial: Attached?
    var nextGeneration: UInt64 = 1
    var rtt: Duration?
    var attempt = 0
    var connectTask: Task<Void, Never>?
    var retryTask: Task<Void, Never>?
    var handshakeTask: Task<Void, Never>?
    var resumeWindowTask: Task<Void, Never>?

    // Channels.
    var channels: [UInt32: ChannelRecord] = [:]
    var nextChannelID: UInt32
    var nextWaiterID: UInt64 = 1
    var nextIncarnation: UInt64 = 1
    /// Closed records whose consumer has not taken `.closed` yet, by
    /// incarnation. Their wire id is free for reuse.
    var retired: [UInt64: ChannelRecord] = [:]
    /// Highest channel id the peer opened in this epoch; a re-declared id at
    /// or below it that has no record was closed and is answered with close.
    var highestPeerChannelID: UInt32 = 0
    /// Identifies the current connect task; stale completions are ignored.
    var connectToken: UInt64 = 0

    // Pump.
    var outbound = OutboundQueue()
    var pumpWaiter: CheckedContinuation<Void, Never>?
    var pumpTask: Task<Void, Never>?
    var pumpFinished = false

    // Subscribers.
    var stateSubscribers = Subscribers<LinkState>()
    var badgeSubscribers = Subscribers<PathBadge>(policy: .bufferingNewest(1))
    // Channel and media publications represent resources. Keep their fan-out
    // queues bounded; `deliverIncoming` closes any value rejected by a full
    // subscriber so a slow feature cannot strand a live channel or track.
    var channelSubscribers = Subscribers<LinkChannel>(policy: .bufferingOldest(64))
    var pendingIncomingChannels: [LinkChannel] = []
    var mediaSubscribers = Subscribers<MediaTrackHandle>(policy: .bufferingOldest(16))
    var pendingIncomingTracks: [MediaTrackHandle] = []

    /// A dialer that reaches `peer` through the carriers of `selector`.
    public init(
        peer: LinkPeer,
        selector: PathSelector,
        configuration: LinkConfiguration = LinkConfiguration(),
        clock: LinkClock = .continuous
    ) {
        self.sessionID = UUID()
        self.role = .dialer(peer: peer, selector: selector)
        self.configuration = configuration
        self.clock = clock
        self.channelSubscribers = Subscribers(policy: .bufferingOldest(configuration.maxPendingIncomingChannels))
        self.mediaSubscribers = Subscribers(policy: .bufferingOldest(configuration.maxPendingIncomingMediaTracks))
        self.epoch = 0
        self.nextChannelID = 1
    }

    /// The accepted side of a session, created by `LinkHost`.
    init(
        acceptedID: UUID,
        epoch: UInt64,
        configuration: LinkConfiguration,
        clock: LinkClock,
        onClose: @escaping @Sendable (LinkSession) async -> Void
    ) {
        self.sessionID = acceptedID
        self.role = .accepted(onClose: onClose)
        self.configuration = configuration
        self.clock = clock
        self.channelSubscribers = Subscribers(policy: .bufferingOldest(configuration.maxPendingIncomingChannels))
        self.mediaSubscribers = Subscribers(policy: .bufferingOldest(configuration.maxPendingIncomingMediaTracks))
        self.epoch = epoch
        self.nextChannelID = 2
    }

    var isDialer: Bool {
        if case .dialer = role { return true }
        return false
    }

    // MARK: - CmuxLink

    public var state: LinkState { machine.state }

    /// The session epoch assigned by the host (0 before the first welcome).
    public var currentEpoch: UInt64 { epoch }

    /// The peer the carrier authenticated (`LinkTransport.peerIdentity`).
    /// On the host it is fixed by the transport that started the session;
    /// `LinkHost` never resumes the session on another identity.
    public var peerIdentity: LinkPeerIdentity? { authenticatedPeer }

    public var badge: PathBadge? {
        guard let current, machine.state.isLive else { return nil }
        return PathBadge(path: current.path, rtt: rtt)
    }

    public func states() -> AsyncStream<LinkState> {
        stateSubscribers.add(initial: [machine.state]) { [weak self] id in
            Task { await self?.removeStateSubscriber(id) }
        }
    }

    public func pathBadges() -> AsyncStream<PathBadge> {
        badgeSubscribers.add(initial: badge.map { [$0] } ?? []) { [weak self] id in
            Task { await self?.removeBadgeSubscriber(id) }
        }
    }

    public func incomingChannels() -> AsyncStream<LinkChannel> {
        let initial = pendingIncomingChannels
        pendingIncomingChannels.removeAll()
        return channelSubscribers.add(initial: initial) { [weak self] id in
            Task { await self?.removeChannelSubscriber(id) }
        }
    }

    public func incomingMediaTracks() -> AsyncStream<MediaTrackHandle> {
        let initial = pendingIncomingTracks
        pendingIncomingTracks.removeAll()
        return mediaSubscribers.add(initial: initial) { [weak self] id in
            Task { await self?.removeMediaSubscriber(id) }
        }
    }

    public func connect() {
        guard isDialer, machine.state == .idle else { return }
        ensurePump()
        attempt = 1
        apply(.attemptStarted(1))
        startAttempt()
    }

    public func networkDidChange() {
        guard isDialer, !machine.state.isClosed else { return }
        switch machine.state {
        case .connecting, .reconnecting:
            guard connectTask == nil, pendingDial == nil else { return }
            retryTask?.cancel()
            retryTask = nil
            startAttempt()
        case .connected, .degraded:
            retryTask?.cancel()
            retryTask = nil
            startUpgrade()
        default:
            break
        }
    }

    public func publishMediaTrack(_ descriptor: MediaTrackDescriptor) async throws -> MediaTrackHandle {
        if case let .closed(reason) = machine.state { throw LinkError.closed(reason) }
        guard let current else { throw LinkError.notConnected }
        guard current.capabilities.carriesMedia else { throw LinkError.unsupportedOnPath(current.path.kind) }
        return try await current.transport.publishMediaTrack(descriptor)
    }

    public func close() {
        finish(.local, notifyPeer: true)
    }

    // MARK: - State publication

    func apply(_ event: LinkStateEvent) {
        guard machine.apply(event) else { return }
        stateSubscribers.yield(machine.state)
        publishBadge()
    }

    func publishBadge() {
        if let badge { badgeSubscribers.yield(badge) }
    }

    func removeStateSubscriber(_ id: UUID) { stateSubscribers.remove(id) }
    func removeBadgeSubscriber(_ id: UUID) { badgeSubscribers.remove(id) }
    func removeChannelSubscriber(_ id: UUID) { channelSubscribers.remove(id) }
    func removeMediaSubscriber(_ id: UUID) { mediaSubscribers.remove(id) }

    func deliverIncoming(_ channel: LinkChannel) {
        if channelSubscribers.isEmpty {
            guard pendingIncomingChannels.count < configuration.maxPendingIncomingChannels else {
                rejectIncomingChannel(channel)
                return
            }
            pendingIncomingChannels.append(channel)
        } else {
            let dropped = channelSubscribers.yield(channel)
            // `.bufferingOldest` drops the newly published handle. Refuse it
            // only when every subscriber was full; another subscriber may
            // still own the same handle and continue consuming it.
            if dropped.count == channelSubscribers.count { rejectIncomingChannel(channel) }
        }
    }

    func deliverIncoming(_ track: MediaTrackHandle) {
        if mediaSubscribers.isEmpty {
            guard pendingIncomingTracks.count < configuration.maxPendingIncomingMediaTracks else {
                Task { await track.stop() }
                return
            }
            pendingIncomingTracks.append(track)
        } else {
            let dropped = mediaSubscribers.yield(track)
            if dropped.count == mediaSubscribers.count { Task { await track.stop() } }
        }
    }

    // MARK: - Close

    /// Terminal: every channel ends, waiters fail, the peer is told when
    /// `notifyPeer` and a transport is live.
    func finish(_ reason: LinkCloseReason, notifyPeer: Bool) {
        guard !machine.state.isClosed else { return }
        apply(.close(reason))
        for task in [connectTask, retryTask, handshakeTask, resumeWindowTask] { task?.cancel() }
        connectTask = nil
        retryTask = nil
        handshakeTask = nil
        resumeWindowTask = nil

        for id in channels.keys { endChannel(id, reason: .sessionClosed(reason), error: LinkError.closed(reason)) }

        if let pending = pendingDial {
            pendingDial = nil
            closeTransportLater(pending.transport)
        }
        outbound.removeAll()
        if let current {
            if notifyPeer {
                outbound.enqueueControl(OutboundItem(
                    frame: .sessionClose(Self.closeCode(for: reason)), lane: .control,
                    bytes: 3, enqueuedAt: clock.now, after: .closeTransport
                ))
            } else {
                closeTransportLater(current.transport)
                self.current = nil
            }
        }
        pumpFinished = true
        wakePump()

        stateSubscribers.finish()
        badgeSubscribers.finish()
        channelSubscribers.finish()
        mediaSubscribers.finish()
        if case let .accepted(onClose) = role {
            Task { await onClose(self) }
        }
    }

    static func closeCode(for reason: LinkCloseReason) -> SessionCloseCode {
        switch reason {
        case .unauthorized: .unauthorized
        case .protocolViolation: .protocolViolation
        default: .normal
        }
    }

    nonisolated func closeTransportLater(_ transport: any LinkTransport) {
        Task { await transport.close() }
    }
}
