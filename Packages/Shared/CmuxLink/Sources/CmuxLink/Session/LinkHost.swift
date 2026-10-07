import Foundation

/// The accepting side: reads the `hello` on every transport a carrier's
/// acceptor yields, resumes the named session when its epoch matches, and
/// otherwise starts a session with a new epoch. A new epoch tells the dialer
/// that nothing from before can be resumed.
public actor LinkHost {
    private let acceptor: any LinkAcceptor
    private let configuration: LinkConfiguration
    private let clock: LinkClock
    private var sessionsByID: [UUID: LinkSession] = [:]
    private var subscribers = Subscribers<LinkSession>(policy: .bufferingOldest(64))
    private var pendingSessions: [LinkSession] = []
    private var acceptTask: Task<Void, Never>?
    private var nextEpoch: UInt64
    private var isClosed = false

    public init(
        acceptor: any LinkAcceptor,
        configuration: LinkConfiguration = LinkConfiguration(),
        clock: LinkClock = .continuous
    ) {
        self.acceptor = acceptor
        self.configuration = configuration
        self.clock = clock
        self.subscribers = Subscribers(policy: .bufferingOldest(configuration.maxPendingSessions))
        // Epochs differ across host restarts without persisted state.
        self.nextEpoch = UInt64.random(in: 1...(UInt64.max >> 2))
    }

    /// Starts accepting transports. Idempotent.
    public func start() {
        guard acceptTask == nil, !isClosed else { return }
        let incoming = acceptor.incoming
        acceptTask = Task { [weak self] in
            for await transport in incoming {
                guard let self else { return }
                self.serve(transport)
            }
        }
    }

    /// New sessions (not resumptions), including ones accepted before the
    /// first subscriber.
    public func sessions() -> AsyncStream<LinkSession> {
        let initial = pendingSessions
        pendingSessions.removeAll()
        return subscribers.add(initial: initial) { [weak self] id in
            Task { await self?.removeSubscriber(id) }
        }
    }

    public var activeSessionCount: Int { sessionsByID.count }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        acceptTask?.cancel()
        acceptTask = nil
        let all = Array(sessionsByID.values)
        sessionsByID.removeAll()
        subscribers.finish()
        for session in all { await session.close() }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.remove(id)
    }

    /// Removes only this session: a replacement under the same id stays.
    private func sessionClosed(_ session: LinkSession) {
        if sessionsByID[session.sessionID] === session {
            sessionsByID[session.sessionID] = nil
        }
    }

    /// One reader per transport: routes the hello, then forwards every
    /// later event to the session in order.
    private nonisolated func serve(_ transport: any LinkTransport) {
        Task { [weak self] in
            var session: LinkSession?
            var generation: UInt64 = 0
            for await event in transport.events {
                if let session {
                    await session.handle(event, generation: generation)
                    continue
                }
                guard case let .frame(frame) = event else {
                    if case .closed = event { return }
                    continue
                }
                guard let self,
                      case let .hello(id, epoch)? = try? LinkFrame(decoding: frame.bytes),
                      let (routed, resumed) = await self.route(id: id, epoch: epoch, identity: transport.peerIdentity) else {
                    await transport.close()
                    return
                }
                session = routed
                generation = await routed.attachAccepted(transport, resumed: resumed)
            }
        }
    }

    private func route(id: UUID, epoch: UInt64, identity: LinkPeerIdentity?) async -> (LinkSession, Bool)? {
        guard !isClosed else { return nil }
        if let existing = sessionsByID[id] {
            // A session belongs to the peer that started it: a transport
            // that proved another key of the same kind is refused, neither
            // resumed nor allowed to replace it. Another key kind is another
            // carrier (B4 X25519, B2 P-256) of possibly the same device, so
            // migration stays possible; the app-level proof (B5 hello)
            // binds the device across carriers.
            if let owner = await existing.peerIdentity {
                guard let identity, owner.keyKind != identity.keyKind || owner.sameKey(as: identity) else {
                    return nil
                }
            }
            let existingEpoch = await existing.currentEpoch
            let closed = await existing.state.isClosed
            if !closed, epoch != 0, existingEpoch == epoch {
                return (existing, true)
            }
            sessionsByID[id] = nil
            if !closed { await existing.close() }
        }
        // Do not retain accepted sessions indefinitely when app startup has
        // not installed a consumer for `sessions()` yet.
        if subscribers.isEmpty, pendingSessions.count >= configuration.maxPendingSessions { return nil }
        let session = LinkSession(
            acceptedID: id,
            epoch: nextEpoch,
            configuration: configuration,
            clock: clock,
            onClose: { [weak self] session in await self?.sessionClosed(session) }
        )
        nextEpoch &+= 1
        sessionsByID[id] = session
        if subscribers.isEmpty {
            pendingSessions.append(session)
        } else {
            let dropped = subscribers.yield(session)
            // `.bufferingOldest` drops the newly accepted session. If every
            // subscriber is full, close it immediately; a subscriber that did
            // receive it remains the owner of the live session.
            if dropped.count == subscribers.count { Task { await session.close() } }
        }
        return (session, false)
    }
}
