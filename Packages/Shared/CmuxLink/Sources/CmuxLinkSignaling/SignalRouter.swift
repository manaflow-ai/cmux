public import CmuxLink

/// Demultiplexes one install's signals by session (b2-webrtc.md section 4).
/// It reads the channel's `incoming` once; each live session gets its own
/// inbox, and an `offer` for an unknown session opens a new inbox delivered
/// to the acceptor of the offer's carrier (`newSessions(for:)`), so V1 and
/// V2 share one host socket. Other messages for unknown sessions, and offers
/// for a carrier nobody accepts, are dropped: signals never queue.
public actor SignalRouter {
    /// A session someone else started: its inbox starts with the offer.
    public struct Incoming: Sendable {
        public let session: String
        public let inbox: AsyncStream<SignalMessage>
    }

    public nonisolated let channel: any SignalingChannel
    private var acceptors: [CarrierKind: AsyncStream<Incoming>.Continuation] = [:]
    private var inboxes: [String: AsyncStream<SignalMessage>.Continuation] = [:]
    private var reader: Task<Void, Never>?

    public init(channel: any SignalingChannel) {
        self.channel = channel
    }

    /// Offers for `carrier` that start a new session. One acceptor per
    /// carrier; a second call replaces the first.
    public func newSessions(for carrier: CarrierKind) -> AsyncStream<Incoming> {
        start()
        let (stream, sink) = AsyncStream.makeStream(of: Incoming.self, bufferingPolicy: .bufferingNewest(64))
        acceptors[carrier]?.finish()
        acceptors[carrier] = sink
        return stream
    }

    /// Starts reading the channel (idempotent).
    public func start() {
        guard reader == nil else { return }
        let incoming = channel.incoming
        reader = Task { [weak self] in
            for await message in incoming {
                guard let self else { return }
                await self.route(message)
            }
            await self?.finishAll()
        }
    }

    /// Registers a session this side started; its messages go to the inbox.
    public func register(_ session: String) -> AsyncStream<SignalMessage> {
        start()
        let (stream, sink) = AsyncStream.makeStream(of: SignalMessage.self, bufferingPolicy: .unbounded)
        inboxes[session]?.finish()
        inboxes[session] = sink
        return stream
    }

    public func unregister(_ session: String) {
        inboxes.removeValue(forKey: session)?.finish()
    }

    public var liveSessions: Int { inboxes.count }

    func route(_ message: SignalMessage) {
        if let sink = inboxes[message.session] {
            sink.yield(message)
            return
        }
        guard case let .offer(_, _, carrier, _) = message.payload, let acceptor = acceptors[carrier] else { return }
        let (stream, sink) = AsyncStream.makeStream(of: SignalMessage.self, bufferingPolicy: .unbounded)
        inboxes[message.session] = sink
        sink.yield(message)
        acceptor.yield(Incoming(session: message.session, inbox: stream))
    }

    private func finishAll() {
        for sink in inboxes.values { sink.finish() }
        inboxes = [:]
        for sink in acceptors.values { sink.finish() }
        acceptors = [:]
    }

    public func stop() {
        reader?.cancel()
        reader = nil
        finishAll()
    }
}
