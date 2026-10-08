public import CmuxLink

/// Demultiplexes one install's signals by session (b2-webrtc.md section 4).
/// It reads the channel's `incoming` once; each live session gets its own
/// inbox, and an `offer` for an unknown session opens a new inbox delivered
/// to the acceptor of the offer's carrier (`newSessions(for:)`), so V1 and
/// V2 share one host socket. Other messages for unknown sessions, and offers
/// for a carrier nobody accepts, are dropped: signals never queue.
///
/// Every buffer is bounded. A session inbox holds `inboxLimit` signals; a
/// session that outruns its reader is ended (its inbox finishes, so the
/// handshake fails and is retried) instead of losing a signal from the middle
/// of the exchange. An acceptor holds `pendingSessionLimit` new sessions; an
/// offer past that is refused (its inbox is never registered). `stop()` is
/// terminal: a late acceptor or dialer receives a finished stream instead of
/// reopening the channel after its owner has torn down.
public actor SignalRouter {
    /// Signals queued for one session before the session is ended.
    public static let inboxLimit = 256
    /// New sessions queued for one acceptor before offers are refused.
    public static let pendingSessionLimit = 64

    /// A session someone else started: its inbox starts with the offer.
    public struct Incoming: Sendable {
        public let session: String
        public let inbox: AsyncStream<SignalMessage>
    }

    public nonisolated let channel: any SignalingChannel
    private var acceptors: [CarrierKind: AsyncStream<Incoming>.Continuation] = [:]
    private var inboxes: [String: AsyncStream<SignalMessage>.Continuation] = [:]
    private var reader: Task<Void, Never>?
    private var closed = false

    public init(channel: any SignalingChannel) {
        self.channel = channel
    }

    /// Offers for `carrier` that start a new session. One acceptor per
    /// carrier; a second call replaces the first.
    public func newSessions(for carrier: CarrierKind) -> AsyncStream<Incoming> {
        guard !closed else { return Self.finishedStream() }
        start()
        let (stream, sink) = AsyncStream.makeStream(of: Incoming.self, bufferingPolicy: .bufferingOldest(Self.pendingSessionLimit))
        acceptors[carrier]?.finish()
        acceptors[carrier] = sink
        return stream
    }

    /// Starts reading the channel (idempotent).
    public func start() {
        guard reader == nil, !closed else { return }
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
        guard !closed else { return Self.finishedStream() }
        start()
        let (stream, sink) = Self.makeInbox()
        inboxes[session]?.finish()
        inboxes[session] = sink
        return stream
    }

    public func unregister(_ session: String) {
        inboxes.removeValue(forKey: session)?.finish()
    }

    public var liveSessions: Int { inboxes.count }

    func route(_ message: SignalMessage) {
        guard !closed else { return }
        if let sink = inboxes[message.session] {
            if case .dropped = sink.yield(message) { unregister(message.session) }
            return
        }
        guard case let .offer(_, _, carrier, _) = message.payload, let acceptor = acceptors[carrier] else { return }
        let (stream, sink) = Self.makeInbox()
        sink.yield(message)
        switch acceptor.yield(Incoming(session: message.session, inbox: stream)) {
        case .enqueued:
            inboxes[message.session] = sink
        case .dropped, .terminated:
            sink.finish()
        @unknown default:
            sink.finish()
        }
    }

    private static func makeInbox() -> (AsyncStream<SignalMessage>, AsyncStream<SignalMessage>.Continuation) {
        AsyncStream.makeStream(of: SignalMessage.self, bufferingPolicy: .bufferingOldest(inboxLimit))
    }

    private static func finishedStream<Element>() -> AsyncStream<Element> {
        let (stream, sink) = AsyncStream<Element>.makeStream()
        sink.finish()
        return stream
    }

    private func finishAll() {
        for sink in inboxes.values { sink.finish() }
        inboxes = [:]
        for sink in acceptors.values { sink.finish() }
        acceptors = [:]
    }

    public func stop() {
        guard !closed else { return }
        closed = true
        reader?.cancel()
        reader = nil
        finishAll()
    }
}
