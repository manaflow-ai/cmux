public import Foundation
public import IrohLib

/// Serialized writer for one QUIC send stream: concurrent senders cannot
/// interleave bytes mid-frame.
public actor IrxStreamWriter {
    private let stream: SendStream
    private var finished = false

    init(_ stream: SendStream) {
        self.stream = stream
    }

    public func write(_ data: Data) async throws {
        guard !finished else { throw IrxFrameCodecError.unexpectedEOF }
        try await stream.writeAll(buf: data)
    }

    public func writeControlFrame(_ value: some Encodable) async throws {
        try await write(IrxFrameCodec.encode(value))
    }

    public func setPriority(_ priority: Int32) async throws {
        try await stream.setPriority(p: priority)
    }

    public func finish() async {
        guard !finished else { return }
        finished = true
        try? await stream.finish()
    }

    public func reset(errorCode: UInt64) async {
        finished = true
        try? await stream.reset(errorCode: errorCode)
    }
}

/// Buffered reader for one QUIC receive stream. Single-consumer: exactly one
/// component owns each reader (the field bug this kills: a second drain loop
/// starves the real consumer frame by frame).
public actor IrxStreamReader {
    private let stream: RecvStream
    private var buffer = Data()
    private var eof = false

    init(_ stream: RecvStream) {
        self.stream = stream
    }

    /// One length-prefixed control frame body, or nil on EOF.
    public func readControlFrameBody() async throws -> Data? {
        while true {
            if buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard length <= IrxProtocol.maximumControlFrameByteCount else {
                    throw IrxFrameCodecError.frameTooLarge(length)
                }
                if buffer.count >= 4 + length {
                    let body = Data(buffer.dropFirst(4).prefix(length))
                    buffer.removeFirst(4 + length)
                    return body
                }
            }
            guard !eof else { return nil }
            let chunk = try await stream.read(sizeLimit: 1 << 16)
            if chunk.isEmpty {
                eof = true
                return nil
            }
            buffer.append(chunk)
        }
    }

    public func readControlFrame<T: Decodable>(_ type: T.Type) async throws -> T? {
        guard let body = try await readControlFrameBody() else { return nil }
        return try IrxFrameCodec.decode(type, from: body)
    }

    /// Raw passthrough: whatever bytes are available (buffered first), or nil
    /// on EOF. Application framing above this is the payload's own business.
    public func readRaw() async throws -> Data? {
        try await readRaw(maximumByteCount: 1 << 16)
    }

    /// Bounded raw read for consumers that manage their own buffers.
    public func readRaw(maximumByteCount: Int) async throws -> Data? {
        let bound = max(1, maximumByteCount)
        if !buffer.isEmpty {
            let drained = buffer.prefix(bound)
            buffer.removeFirst(drained.count)
            return Data(drained)
        }
        guard !eof else { return nil }
        let chunk = try await stream.read(sizeLimit: UInt32(min(bound, 1 << 16)))
        if chunk.isEmpty {
            eof = true
            return nil
        }
        return chunk
    }

    public func stop() async {
        await stop(errorCode: 0)
    }

    public func stop(errorCode: UInt64) async {
        try? await stream.stop(errorCode: errorCode)
    }
}

/// One application lane on one bidirectional QUIC stream.
public struct IrxLaneStream: Sendable {
    public let descriptor: IrxLaneDescriptor
    public let writer: IrxStreamWriter
    public let reader: IrxStreamReader

    public func close() async {
        await writer.finish()
        await reader.stop()
    }
}

public enum IrxConnectionError: Error, Sendable {
    case closed(IrxTermination?)
    case admissionTimeout
    case malformedPeerFrame
    case laneRejected(IrxLaneError)
}

/// One live irx QUIC connection: lane open/accept with descriptor framing,
/// continuous keepalive, path attribution sampling, and reasoned closes.
public actor IrxConnection {
    public enum Role: String, Sendable {
        case dialer, acceptor
    }

    nonisolated public let role: Role
    nonisolated public let remoteEndpointIDHex: String
    private let connection: Connection
    /// Instant of the most recent keepalive pong; nil before the first pong.
    /// Foreground staleness checks read this to decide zombie-vs-live after
    /// a suspension (a QUIC connection can be long dead without isClosed).
    public private(set) var lastPongAt: ContinuousClock.Instant?
    private let journal: IrxJournal
    private var closedFlag = false
    private var localTermination: IrxTermination?
    private var keepaliveTask: Task<Void, Never>?
    private var pingSeq: UInt64 = 0

    public init(connection: Connection, role: Role, journal: IrxJournal) {
        self.connection = connection
        self.role = role
        self.journal = journal
        remoteEndpointIDHex = connection.remoteId().toBytes()
            .map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated var underlying: Connection { connection }

    public var isClosed: Bool {
        closedFlag || connection.closeReason() != nil
    }

    /// Raises the number of streams the REMOTE side may open, called by the
    /// server right after admission (lanes) and by the client for the
    /// server-opened events lane.
    public func raiseRemoteStreamCredit(bi: UInt64, uni: UInt64) {
        try? connection.setMaxConcurrentBiStreams(count: bi)
        try? connection.setMaxConcurrentUniStreams(count: uni)
    }

    /// Opens a bidirectional lane and sends its descriptor.
    public func openLane(_ descriptor: IrxLaneDescriptor) async throws -> IrxLaneStream {
        let stream = try await connection.openBi()
        let writer = IrxStreamWriter(stream.send())
        let reader = IrxStreamReader(stream.recv())
        try await writer.writeControlFrame(descriptor)
        return IrxLaneStream(descriptor: descriptor, writer: writer, reader: reader)
    }

    /// Opens the server->client unidirectional events lane.
    public func openUniLane(_ descriptor: IrxLaneDescriptor) async throws -> IrxStreamWriter {
        let stream = try await connection.openUni()
        let writer = IrxStreamWriter(stream)
        try await writer.writeControlFrame(descriptor)
        return writer
    }

    /// Accepts the next bidirectional lane (server side, post-admission).
    /// Returns nil once the connection is closed.
    public func acceptLane() async -> IrxLaneStream? {
        while true {
            do {
                let stream = try await connection.acceptBi()
                let reader = IrxStreamReader(stream.recv())
                let writer = IrxStreamWriter(stream.send())
                guard
                    let descriptor = try await reader.readControlFrame(
                        IrxLaneDescriptor.self)
                else {
                    await writer.finish()
                    continue
                }
                return IrxLaneStream(descriptor: descriptor, writer: writer, reader: reader)
            } catch {
                closedFlag = true
                return nil
            }
        }
    }

    /// Accepts the next unidirectional lane (client side: the events lane).
    public func acceptUniLane() async throws -> (IrxLaneDescriptor, IrxStreamReader)? {
        do {
            let stream = try await connection.acceptUni()
            let reader = IrxStreamReader(stream)
            guard
                let descriptor = try await reader.readControlFrame(IrxLaneDescriptor.self)
            else { return nil }
            return (descriptor, reader)
        } catch {
            closedFlag = true
            return nil
        }
    }

    /// The selected QUIC path right now, for relay attribution evidence.
    public nonisolated func selectedPathDescription() -> String {
        let paths = connection.paths()
        guard let selected = paths.first(where: { $0.isSelected }) ?? paths.first else {
            return "none"
        }
        return "\(selected.isRelay ? "relay" : "direct"):\(selected.remoteAddr)"
    }

    /// Continuous client-side keepalive on a dedicated lane: one tiny ping
    /// every interval, pong deadline enforced per ping, every exchange
    /// journaled with RTT and the selected path (the soak's relay-attribution
    /// evidence). A single miss re-pings immediately (journaled as a `miss`,
    /// not a death: one transient stall must never sever a healthy session);
    /// `IrxProtocol.keepaliveStrikeLimit` consecutive misses close with
    /// `keepalive-timeout` and report death so the engine redials at once.
    public func startClientKeepalive(
        interval: Duration = IrxProtocol.keepaliveInterval,
        deadline: Duration = IrxProtocol.keepaliveDeadline,
        onDeath: @escaping @Sendable () async -> Void
    ) async throws {
        guard keepaliveTask == nil else { return }
        let lane = try await openLane(IrxLaneDescriptor(lane: .keepalive))
        keepaliveTask = Task { [journal] in
            var strikes = 0
            while !Task.isCancelled {
                if strikes == 0 {
                    try? await Task.sleep(for: interval)
                }
                guard !Task.isCancelled else { return }
                let seq = await self.nextPingSeq()
                let sentAt = DispatchTime.now()
                do {
                    try await lane.writer.writeControlFrame(IrxPing(seq: seq, pong: false))
                    let pong = try await withIrxDeadline(deadline) {
                        () -> IrxPing? in
                        while true {
                            guard
                                let reply = try await lane.reader.readControlFrame(
                                    IrxPing.self)
                            else { return nil }
                            if reply.pong, reply.seq == seq { return reply }
                        }
                    }
                    guard pong != nil else {
                        throw IrxConnectionError.closed(nil)
                    }
                    let rttMs =
                        (DispatchTime.now().uptimeNanoseconds
                            - sentAt.uptimeNanoseconds) / 1_000_000
                    journal.record(
                        "keepalive", "pong",
                        [
                            "seq": String(seq),
                            "rtt_ms": String(rttMs),
                            "path": self.selectedPathDescription(),
                        ]
                    )
                    await self.notePong()
                    strikes = 0
                } catch {
                    guard !Task.isCancelled else { return }
                    strikes += 1
                    if strikes < IrxProtocol.keepaliveStrikeLimit {
                        journal.record(
                            "keepalive", "miss",
                            [
                                "seq": String(seq),
                                "strike": String(strikes),
                                "path": self.selectedPathDescription(),
                            ]
                        )
                        continue
                    }
                    journal.record(
                        "keepalive", "timeout",
                        ["seq": String(seq), "path": self.selectedPathDescription()]
                    )
                    await self.close(code: .keepaliveTimeout, origin: .transport)
                    await onDeath()
                    return
                }
            }
        }
    }

    /// Authorizes NAT traversal for this connection (automatic path mode
    /// only): iroh then exchanges direct candidates over the relay side
    /// channel and upgrades off the relay make-before-break. Failure is
    /// journaled, never fatal — the relay path keeps carrying the session
    /// when traversal cannot.
    public func authorizeDirectPaths() async {
        do {
            try await connection.authorizeNatTraversal()
            journal.record(
                "endpoint", "nat-traversal-authorized",
                ["remote": String(remoteEndpointIDHex.prefix(12))]
            )
        } catch {
            journal.record(
                "endpoint", "nat-traversal-authorize-failed",
                ["error": String(describing: error)]
            )
        }
    }

    private func notePong() {
        lastPongAt = ContinuousClock.now
    }

    /// Server-side keepalive responder for one accepted keepalive lane.
    public nonisolated func respondKeepalive(on lane: IrxLaneStream) -> Task<Void, Never> {
        Task { [journal] in
            while !Task.isCancelled {
                do {
                    guard let ping = try await lane.reader.readControlFrame(IrxPing.self)
                    else { return }
                    guard !ping.pong else { continue }
                    try await lane.writer.writeControlFrame(
                        IrxPing(seq: ping.seq, pong: true))
                    journal.record(
                        "keepalive", "ponged",
                        ["seq": String(ping.seq), "path": self.selectedPathDescription()]
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func nextPingSeq() -> UInt64 {
        pingSeq += 1
        return pingSeq
    }

    /// Reasoned close: the code rides the QUIC CONNECTION_CLOSE itself.
    public func close(code: IrxCloseCode, origin: IrxTermination.Origin) async {
        guard !closedFlag else { return }
        closedFlag = true
        localTermination = IrxTermination(origin: origin, code: code.rawValue)
        keepaliveTask?.cancel()
        keepaliveTask = nil
        try? connection.close(errorCode: 1, reason: code.reasonData)
        journal.record(
            "connection", "closed-locally",
            ["code": code.rawValue, "remote": String(remoteEndpointIDHex.prefix(12))]
        )
    }

    /// Resolves once the connection has ended, returning the attributed
    /// termination. "connection-lost" (no parsable cause) is itself a signal
    /// the soak analyzer treats as a failure.
    public func termination() async -> IrxTermination {
        if let localTermination { return localTermination }
        let rendered: String
        if let reason = connection.closeReason() {
            rendered = reason
        } else {
            rendered = await connection.closed()
        }
        keepaliveTask?.cancel()
        keepaliveTask = nil
        closedFlag = true
        if let local = localTermination { return local }
        if let code = IrxCloseCode.parse(fromRenderedCause: rendered) {
            return IrxTermination(origin: .remote, code: code.rawValue)
        }
        return IrxTermination(origin: .transport, code: "connection-lost(\(rendered.prefix(80)))")
    }
}

/// Bounded deadline for one async operation. An intentional, cancellable
/// timeout through the clock (never a synchronization substitute): the racing
/// sleep is cancelled the moment the operation resolves.
public func withIrxDeadline<T: Sendable>(
    _ limit: Duration,
    operation: @escaping @Sendable () async throws -> T?
) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            return nil
        }
        let first = try await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
