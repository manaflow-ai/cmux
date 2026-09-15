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
    /// This is diagnostic history; age alone never proves the peer is dead.
    public private(set) var lastPongAt: ContinuousClock.Instant?
    private let journal: IrxJournal
    private var closedFlag = false
    private var nativeClosureObserved = false
    private var localTermination: IrxTermination?
    private var keepaliveTask: Task<Void, Never>?
    private var pingSeq: UInt64 = 0
    private var applicationActive = true
    private var keepaliveGeneration: UInt64 = 0
    private var keepaliveSettings: (interval: Duration, deadline: Duration, onDeath: @Sendable () async -> Void)?
    private var probeTask: Task<Bool, Never>?
    private var probeID: UUID?
    private var probeLane: IrxLaneStream?
    private var closureWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledClosureWaiters = Set<UUID>()
    private var closureWatcher: Task<Void, Never>?

    public init(connection: Connection, role: Role, journal: IrxJournal) {
        self.connection = connection
        self.role = role
        self.journal = journal
        remoteEndpointIDHex = connection.remoteId().toBytes()
            .map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated var underlying: Connection { connection }

    public var isClosed: Bool {
        closedFlag || nativeClosureObserved || connection.closeReason() != nil
    }

    /// Explicit method form for callers that need to query liveness across
    /// actor boundaries without confusing the property with a function.
    public func isConnectionClosed() -> Bool {
        isClosed
    }

    /// Returns recent diagnostic evidence. A false result does not establish
    /// peer death; callers must probe before replacing an open connection.
    public func hasRecentKeepalive(within age: Duration) -> Bool {
        guard let lastPongAt else { return false }
        return ContinuousClock.now - lastPongAt <= age
    }

    /// Registers a cancellation-aware waiter for the complete QUIC
    /// connection, shared by all RPC lanes on this session.
    public func makeClosureObservationID() -> UUID {
        let observationID = UUID()
        if closureWatcher == nil {
            let driver = connection
            closureWatcher = Task { [weak self] in
                _ = await driver.closed()
                await self?.finishClosureWaiters()
            }
        }
        return observationID
    }

    /// Waits for a registered complete-connection observation to fire.
    public func waitForClosure(observationID: UUID) async {
        if isClosed || cancelledClosureWaiters.remove(observationID) != nil {
            return
        }
        await withCheckedContinuation { continuation in
            if isClosed || cancelledClosureWaiters.remove(observationID) != nil {
                continuation.resume()
            } else {
                closureWaiters[observationID] = continuation
            }
        }
    }

    /// Cancels one complete-connection observation without closing the
    /// connection itself.
    public func cancelClosureObservation(observationID: UUID) {
        if let continuation = closureWaiters.removeValue(forKey: observationID) {
            continuation.resume()
        } else {
            cancelledClosureWaiters.insert(observationID)
        }
    }

    private func finishClosureWaiters() {
        // Native closure can race registration. Mark the terminal state before
        // draining waiters so a waiter registered after the watcher fires
        // completes immediately instead of hanging forever.
        nativeClosureObserved = true
        let waiters = closureWaiters
        closureWaiters.removeAll(keepingCapacity: false)
        cancelledClosureWaiters.removeAll(keepingCapacity: false)
        for continuation in waiters.values {
            continuation.resume()
        }
        closureWatcher = nil
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

    /// Starts one periodic peer probe owner. A failed probe retires its stream;
    /// another attempt uses a fresh stream on the same QUIC connection.
    public func startClientKeepalive(
        interval: Duration = IrxProtocol.keepaliveInterval,
        deadline: Duration = IrxProtocol.keepaliveDeadline,
        onDeath: @escaping @Sendable () async -> Void
    ) async throws {
        guard keepaliveSettings == nil, !isClosed, !Task.isCancelled else { return }
        keepaliveSettings = (interval, deadline, onDeath)
        launchKeepalive()
    }

    /// Pauses application probes before suspension without closing QUIC.
    /// A resumed loop begins with zero strikes and a fresh probe deadline.
    public func setApplicationActive(_ active: Bool) {
        guard applicationActive != active else { return }
        applicationActive = active
        keepaliveGeneration &+= 1
        keepaliveTask?.cancel()
        keepaliveTask = nil
        cancelProbe()
        journal.record("keepalive", active ? "resumed" : "suspended")
        if active { launchKeepalive() }
    }

    /// Tests the existing peer with a bounded ping/pong exchange. Concurrent
    /// callers share the current probe; a shorter caller deadline also retires
    /// that probe, so no caller retries a stopped receive stream.
    /// A false result during suspension is inconclusive and must not cause a close.
    public func probeLiveness(deadline: Duration = IrxProtocol.keepaliveDeadline) async -> Bool {
        guard applicationActive, !isClosed, !Task.isCancelled else { return false }
        if let task = probeTask, let id = probeID {
            let result = try? await withIrxDeadlineResult(deadline) { await task.value }
            if case .operation(let alive) = result { return alive == true }
            if probeID == id { cancelProbe() }
            return false
        }
        let id = UUID()
        probeID = id
        let task = Task { () -> Bool in
            let alive = await self.performProbe(id: id, deadline: deadline)
            guard self.probeID == id else { return false }
            // Clear inside the owned task before joined callers can resume.
            self.probeID = nil
            self.probeTask = nil
            if !alive { self.discardProbeLane() }
            return alive
        }
        probeTask = task
        return await task.value
    }

    private func launchKeepalive() {
        guard applicationActive, !isClosed, keepaliveTask == nil, let settings = keepaliveSettings else { return }
        keepaliveGeneration &+= 1
        let generation = keepaliveGeneration
        keepaliveTask = Task {
            var strikes = 0
            while !Task.isCancelled, self.applicationActive, self.keepaliveGeneration == generation {
                if strikes == 0 {
                    do { try await Task.sleep(for: settings.interval) } catch { return }
                }
                guard !Task.isCancelled, self.applicationActive, self.keepaliveGeneration == generation else { return }
                let alive = await self.probeLiveness(deadline: settings.deadline)
                guard !Task.isCancelled, self.applicationActive, self.keepaliveGeneration == generation else { return }
                if alive { strikes = 0; continue }
                strikes += 1
                if strikes < IrxProtocol.keepaliveStrikeLimit {
                    self.journal.record("keepalive", "miss", ["strike": String(strikes),
                        "path": self.selectedPathDescription()])
                    continue
                }
                self.journal.record("keepalive", "timeout", ["path": self.selectedPathDescription()])
                await self.close(code: .keepaliveTimeout, origin: .transport)
                await settings.onDeath()
                return
            }
        }
    }

    private func performProbe(id: UUID, deadline: Duration) async -> Bool {
        let seq = nextPingSeq()
        let sentAt = ContinuousClock.now
        do {
            let result = try await withIrxDeadlineResult(deadline) { [self] in
                try await exchangePing(id: id, seq: seq)
            }
            guard probeID == id, applicationActive, !Task.isCancelled,
                  case .operation(true) = result else { return false }
            notePong()
            let duration = sentAt.duration(to: .now).components
            let milliseconds = duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000
            journal.record("keepalive", "pong", ["seq": String(seq), "rtt_ms": String(milliseconds),
                "path": selectedPathDescription()])
            return true
        } catch { return false }
    }

    private func exchangePing(id: UUID, seq: UInt64) async throws -> Bool? {
        guard probeID == id, applicationActive else { throw CancellationError() }
        let lane: IrxLaneStream
        if let current = probeLane { lane = current }
        else {
            lane = try await openLane(IrxLaneDescriptor(lane: .keepalive))
            guard probeID == id, applicationActive, !Task.isCancelled else {
                await lane.close()
                throw CancellationError()
            }
            probeLane = lane
        }
        try await lane.writer.writeControlFrame(IrxPing(seq: seq, pong: false))
        guard probeID == id, applicationActive, !Task.isCancelled else { throw CancellationError() }
        while let reply = try await lane.reader.readControlFrame(IrxPing.self) {
            guard probeID == id, applicationActive, !Task.isCancelled else { throw CancellationError() }
            if reply.pong, reply.seq == seq { return true }
        }
        return false
    }

    private func cancelProbe() {
        probeID = nil
        probeTask?.cancel()
        probeTask = nil
        discardProbeLane()
    }

    private func discardProbeLane() {
        guard let lane = probeLane else { return }
        probeLane = nil
        // Reset releases an outstanding native read/write without making the
        // protocol deadline wait on cancellation-insensitive FFI cleanup.
        Task {
            await lane.writer.reset(errorCode: 0)
            await lane.reader.stop()
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
        finishClosureWaiters()
        closureWatcher?.cancel()
        closureWatcher = nil
        localTermination = IrxTermination(origin: origin, code: code.rawValue)
        keepaliveTask?.cancel()
        keepaliveTask = nil
        keepaliveSettings = nil
        cancelProbe()
        try? connection.close(errorCode: 1, reason: code.reasonData)
        journal.record(
            "connection", "closed-locally",
            ["code": code.rawValue, "remote": String(remoteEndpointIDHex.prefix(12))]
        )
    }

    /// Returns a close reason that the underlying QUIC connection has already
    /// published, without waiting for the connection to finish closing.
    public func closeReason() -> String? {
        connection.closeReason()
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
        keepaliveSettings = nil
        cancelProbe()
        closedFlag = true
        if let local = localTermination { return local }
        if let code = IrxCloseCode.parse(fromRenderedCause: rendered) {
            return IrxTermination(origin: .remote, code: code.rawValue)
        }
        return IrxTermination(origin: .transport, code: "connection-lost(\(rendered.prefix(80)))")
    }
}
