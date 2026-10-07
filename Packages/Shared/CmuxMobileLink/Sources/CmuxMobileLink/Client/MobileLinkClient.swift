import CmuxLink
import CmuxMobileWire
import Foundation

/// The phone's `cmux.mobile/1` session with one Mac (c1-terminal-rpc.md
/// sections 3 and 9): one `LinkSession`, its session channel (A0 channel 0)
/// with a hello signed by the paired device key, and odd A0 channel ids.
///
/// Generations: a session lives until its link session closes or the link
/// reports a gap on the session channel (the Mac's link host started a new
/// epoch, so nothing from before can be resumed). Then the client drops it,
/// bumps the generation and makes a fresh link session on the next `open`.
/// Channels of an older generation see the same gap or close and reopen.
public actor MobileLinkClient {
    public static let sessionStream = "cmux.mobile/session"
    public static let caps = ["device-proof", "read", "resume"]

    private struct Session {
        let link: LinkSession
        let generation: UInt64
        let hello: Task<HelloOKFrame, any Error>
    }

    public nonisolated let hostID: String
    private let signer: any MobileDeviceSigner
    private let client: HelloClient
    private let makeSession: @Sendable () -> LinkSession
    private let now: @Sendable () -> Date
    private var session: Session?
    private var generation: UInt64 = 0
    private var nextChannelID: UInt32 = 1
    private var closed = false
    private var badgeSubscribers: [UUID: AsyncStream<PathBadge>.Continuation] = [:]
    private var badgeTask: Task<Void, Never>?

    /// - Parameters:
    ///   - client: who sends hello; `install` must equal `signer.install`.
    ///   - makeSession: a new, unconnected `LinkSession` to this Mac (its
    ///     carriers and path policy). Called once per generation.
    public init(hostID: String, signer: any MobileDeviceSigner, client: HelloClient,
                makeSession: @escaping @Sendable () -> LinkSession,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.hostID = hostID
        self.signer = signer
        self.client = client
        self.makeSession = makeSession
        self.now = now
    }

    /// The current generation (0 before the first session).
    public var currentGeneration: UInt64 { generation }

    /// Path and RTT of whichever link session is current, newest first.
    public func pathBadges() -> AsyncStream<PathBadge> {
        let (stream, continuation) = AsyncStream<PathBadge>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        badgeSubscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeBadgeSubscriber(id) }
        }
        return stream
    }

    private func removeBadgeSubscriber(_ id: UUID) {
        badgeSubscribers[id] = nil
    }

    // MARK: Open

    /// Opens one A0 channel: waits for the session's `hello.ok`, opens the
    /// link channel, sends `channel.open` and returns the host's answer.
    public func open(_ request: MobileChannelRequest) async throws -> MobileOpenedChannel {
        let current = try await ensureSession()
        _ = try await current.hello.value
        guard !closed else { throw MobileLinkClientError.closed }
        let id = nextChannelID
        nextChannelID &+= 2
        let link: LinkChannel
        do {
            link = try await current.link.openChannel(
                ChannelDescriptor(stream: request.stream, reliability: .reliableOrdered, priority: request.priority,
                                  budgetBytes: request.budgetBytes),
                resumeFrom: nil)
        } catch {
            sessionEnded(current.generation)
            throw MobileLinkClientError.linkLost
        }
        let channel = MobileChannel(id: id, link: link)
        let generation = current.generation
        return try await Self.handshake(channel, request: request, generation: generation)
    }

    private nonisolated static func handshake(_ channel: MobileChannel, request: MobileChannelRequest,
                                              generation: UInt64) async throws -> MobileOpenedChannel {
        let open = ChannelOpenFrame(channel: channel.id, kind: request.kind, channelClass: request.channelClass,
                                    window: request.window, params: request.params)
        do {
            try await channel.send(frame: .channelOpen(open))
        } catch {
            await channel.abort()
            throw MobileLinkClientError.linkLost
        }
        switch await channel.receive() {
        case .json(let value):
            switch try? MobileFrame(value: value) {
            case .channelOpened(let opened)?:
                return MobileOpenedChannel(channel: channel, opened: opened, generation: generation)
            case .channelRefused(let refused)?:
                await channel.abort()
                throw MobileLinkClientError.refused(code: refused.code, message: refused.message, retryable: refused.retryable)
            default:
                await channel.abort()
                throw MobileLinkClientError.protocolViolation("expected channel.opened or channel.refused")
            }
        case .binary:
            await channel.abort()
            throw MobileLinkClientError.protocolViolation("binary record before channel.opened")
        case .gap, .closed:
            await channel.abort()
            throw MobileLinkClientError.linkLost
        }
    }

    // MARK: Session

    private func ensureSession() async throws -> Session {
        guard !closed else { throw MobileLinkClientError.closed }
        if let session { return session }
        generation += 1
        let link = makeSession()
        let current = generation
        let hello = Task { [weak self] () throws -> HelloOKFrame in
            guard let self else { throw MobileLinkClientError.closed }
            return try await self.runHello(link, generation: current)
        }
        let made = Session(link: link, generation: current, hello: hello)
        session = made
        followBadges(link)
        await link.connect()
        return made
    }

    private func runHello(_ link: LinkSession, generation: UInt64) async throws -> HelloOKFrame {
        let channel: MobileChannel
        do {
            let opened = try await link.openChannel(
                ChannelDescriptor(stream: Self.sessionStream, reliability: .reliableOrdered, priority: .control),
                resumeFrom: nil)
            channel = MobileChannel(id: 0, link: opened)
        } catch {
            sessionEnded(generation)
            throw MobileLinkClientError.linkLost
        }
        do {
            try await channel.send(json: try helloJSON(sessionID: link.sessionID))
        } catch {
            sessionEnded(generation)
            throw error is MobileLinkClientError ? error : MobileLinkClientError.linkLost
        }
        switch await channel.receive() {
        case .json(let value):
            switch try? MobileFrame(value: value) {
            case .helloOK(let ok)?:
                watchSessionChannel(channel, generation: generation)
                return ok
            case .error(let error)?:
                sessionEnded(generation)
                throw MobileLinkClientError.helloRejected(code: error.code, message: error.message)
            default:
                sessionEnded(generation)
                throw MobileLinkClientError.protocolViolation("expected hello.ok")
            }
        case .binary:
            sessionEnded(generation)
            throw MobileLinkClientError.protocolViolation("binary record on the session channel")
        case .gap, .closed:
            sessionEnded(generation)
            throw MobileLinkClientError.linkLost
        }
    }

    private func helloJSON(sessionID: UUID) throws -> JSONValue {
        let hello = HelloFrame(caps: Self.caps, client: client)
        guard case .object(var object) = try MobileFrame.hello(hello).jsonValue else {
            throw MobileLinkClientError.protocolViolation("hello did not encode as an object")
        }
        let issuedAt = Int64(now().timeIntervalSince1970 * 1000)
        let signer = signer
        let proof = try DeviceProof(install: signer.install, keyID: signer.keyID, issuedAt: issuedAt, hostID: hostID,
                                    sessionID: sessionID) { try signer.sign($0) }
        object["auth"] = proof.jsonValue
        return .object(object)
    }

    /// The session channel carries nothing after `hello.ok`. Its gap (a new
    /// link epoch) or close ends the generation.
    private func watchSessionChannel(_ channel: MobileChannel, generation: UInt64) {
        Task { [weak self] in
            while true {
                switch await channel.receive() {
                case .gap, .closed:
                    await self?.sessionEnded(generation)
                    return
                case .json, .binary:
                    continue
                }
            }
        }
    }

    private func followBadges(_ link: LinkSession) {
        badgeTask?.cancel()
        badgeTask = Task { [weak self] in
            for await badge in await link.pathBadges() {
                guard !Task.isCancelled else { return }
                await self?.publish(badge)
            }
        }
    }

    private func publish(_ badge: PathBadge) {
        for continuation in badgeSubscribers.values { continuation.yield(badge) }
    }

    /// Drops the session of `generation` (no-op for an older one) and closes
    /// its link session; the next `open` starts a new generation.
    public func sessionEnded(_ generation: UInt64) {
        guard let session, session.generation == generation else { return }
        self.session = nil
        session.hello.cancel()
        let link = session.link
        Task { await link.close() }
    }

    /// The device's network changed (NWPathMonitor): the current link
    /// session races its carriers again at once (a3-link.md section 3).
    public func networkDidChange() async {
        await session?.link.networkDidChange()
    }

    /// Whether a link session is live or being made (diagnostics, tests).
    public var hasSession: Bool { session != nil }

    /// Ends the current session and refuses later opens.
    public func close() {
        closed = true
        if let session { sessionEnded(session.generation) }
        badgeTask?.cancel()
        badgeTask = nil
        for continuation in badgeSubscribers.values { continuation.finish() }
        badgeSubscribers.removeAll()
    }
}
