import Foundation
import IrohLib

/// One live iroh QUIC connection behind the substrate seam.
///
/// Lane protocol: the DIALER opens lanes; each new bidirectional stream's
/// first frame is `lane.open {name}`. The ACCEPTOR's `lane(_:)` waits until
/// the peer opens that name. This mirrors how the host code already consumes
/// lanes (it awaits "ctl" first, then named lanes on demand).
public actor IrohPeerConnection: PeerConnection {
    /// Determines which peer opens named lanes and which waits for them.
    public enum Role: Sendable {
        /// Opens a stream when a named lane is first requested.
        case dialer
        /// Waits for the remote peer to open the requested named lane.
        case acceptor
    }

    static let laneOpenType = "lane.open"
    static let rawOpenType = "raw.open"

    let connection: Connection
    let role: Role
    let remoteKey: Data
    /// Genuine handshake deadline; injected for deterministic tests and to
    /// ensure a peer cannot park the accept loop forever before sending the
    /// first lane frame.
    let handshakeSleep: @Sendable (Duration) async throws -> Void
    var lanes: [String: IrohLane] = [:]
    /// Reserve names before native I/O suspends. One caller's cancellation
    /// must not abort the shared open; connection shutdown owns these tasks.
    var laneOpenTasks: [String: Task<any TransportLane, Never>] = [:]
    var laneWaiters: [String: [(id: UInt64, continuation: CheckedContinuation<any TransportLane, Never>)]] = [:]
    var laneWaiterTasks: [UInt64: Task<Void, Never>] = [:]
    private var laneWaiterCounter: UInt64 = 0
    private var acceptLoop: Task<Void, Never>?
    /// One bounded worker per accepted bidirectional stream. The accept loop
    /// itself never waits for a peer's `lane.open`/`raw.open` handshake.
    var inboundStreamTasks: [UInt64: Task<Void, Never>] = [:]
    var inboundStreamCounter: UInt64 = 0
    var rawStreamHandler: (@Sendable (String, RawByteStream) async -> Void)?
    var pendingRawStreams: [(String, RawByteStream)] = []
    /// A single FIFO delivery task preserves the arrival order promised by
    /// `onRawStream`; one task per stream could be scheduled out of order.
    var rawDeliveryQueue: [(String, RawByteStream)] = []
    var rawDeliveryHead = 0
    var rawDeliveryTask: Task<Void, Never>?
    var closedFlag = false
    var localCloseRequested = false
    var localTermination: ConnectionTermination?

    static let maxConcurrentInboundStreams = 64
    static let maxLaneCount = 128
    static let inboundOpenDeadline: Duration = .seconds(10)
    private static let laneWaitDeadline: Duration = .seconds(10)

    /// Wraps established QUIC; call ``start()`` to begin accepting incoming streams.
    /// - Parameters:
    ///   - connection: Authenticated QUIC connection whose lifecycle this actor owns.
    ///   - role: Named-lane opening role agreed by dial/accept plumbing.
    ///   - handshakeSleep: Cancellable stream-open deadline sleeper; defaults to a continuous clock.
    public init(
        connection: Connection,
        role: Role,
        handshakeSleep: @escaping @Sendable (Duration) async throws -> Void = { delay in
            try await ContinuousClock().sleep(for: delay)
        }
    ) {
        self.connection = connection
        self.role = role
        self.remoteKey = connection.remoteId().toBytes()
        self.handshakeSleep = handshakeSleep
    }

    /// Must be called once after init (an actor cannot spawn tasks on itself
    /// mid-init); the factory methods on IrohSubstrate do this. Both roles
    /// run the inbound accept loop: the acceptor for peer-opened lanes, the
    /// dialer for host-opened streams (server events over the graduation
    /// bridge). A dialer that never receives one just parks on acceptBi.
    public func start() {
        guard acceptLoop == nil else { return }
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) start \
                role=\(String(describing: self.role), privacy: .public) \
                remote=\(TransportDebugLog.hex8(self.remoteKey), privacy: .public)
                """)
        }
        acceptLoop = Task { await self.runAcceptLoop() }
    }

    /// iroh always authenticates the remote endpoint key during the QUIC
    /// handshake; admission judges grants against THIS (contract 3.5).
    public var authenticatedRemoteKey: Data? { remoteKey }

    /// Whether local shutdown or the underlying QUIC close has made the connection terminal.
    public var isClosed: Bool {
        closedFlag || connection.closeReason() != nil
    }

    /// Graduation bridge: registers the single owner of inbound raw
    /// application streams. Streams that arrived before registration are
    /// delivered immediately, in arrival order.
    public func onRawStream(
        _ handler: @escaping @Sendable (String, RawByteStream) async -> Void
    ) async {
        guard !closedFlag else { return }
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) raw-stream handler \
                registered pendingFlushed=\(self.pendingRawStreams.count, privacy: .public)
                """)
        }
        rawStreamHandler = handler
        rawDeliveryQueue.append(contentsOf: pendingRawStreams)
        pendingRawStreams.removeAll()
        startRawDeliveryIfNeeded()
    }

    /// Graduation bridge: opens one raw application stream. One handshake
    /// frame carries the preamble; every byte after it is unframed and owned
    /// by the caller (identical wire shape to the legacy transport's lanes).
    public func openRawStream(preamble: String) async throws -> RawByteStream {
        guard !closedFlag else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) openRawStream REFUSED \
                    (connection closed) preamble=\(preamble, privacy: .public)
                    """)
            }
            throw TransportError.pipeClosed
        }
        var openedStream: BiStream?
        do {
            let stream = try await connection.openBi()
            openedStream = stream
            guard !closedFlag, !Task.isCancelled else { throw TransportError.pipeClosed }
            let channel = IrohLaneChannel(send: stream.send(), recv: stream.recv())
            try await channel.sendFrame(
                Frame(type: Self.rawOpenType, payload: ["preamble": .string(preamble)]))
            guard !closedFlag, !Task.isCancelled else { throw TransportError.pipeClosed }
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) raw stream opened \
                    preamble=\(preamble, privacy: .public)
                    """)
            }
            return RawByteStream(send: stream.send(), recv: stream.recv(), buffered: Data())
        } catch {
            if let openedStream { await closeUnadoptedStream(openedStream) }
            if TransportDebugLog.enabled {
                TransportDebugLog.core.error(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) openRawStream FAILED \
                    preamble=\(preamble, privacy: .public) \
                    error=\(String(describing: error), privacy: .public)
                    """)
            }
            throw error
        }
    }

    /// Returns an existing lane, opens one as dialer, or waits boundedly as acceptor.
    /// - Parameter name: Logical lane name, subject to the per-connection lane cap.
    /// - Returns: The named lane, or an ended lane after failure, timeout, or closure.
    public func lane(_ name: String) async -> any TransportLane {
        guard !Task.isCancelled else { return DeadLane(name: name) }
        if let existing = lanes[name] { return existing }
        if closedFlag {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) lane \
                    name=\(name, privacy: .public) -> dead lane (connection closed)
                    """)
            }
            return DeadLane(name: name)
        }
        switch role {
        case .dialer:
            if let opening = laneOpenTasks[name] { return await awaitNamedLane(opening, name: name) }
            guard !Task.isCancelled,
                lanes.count + laneOpenTasks.count < Self.maxLaneCount
            else {
                if TransportDebugLog.enabled {
                    TransportDebugLog.core.error(
                        "conn \(TransportDebugLog.id(self), privacy: .public) lane limit reached (\(Self.maxLaneCount, privacy: .public)); refusing name=\(name, privacy: .public)")
                }
                return DeadLane(name: name)
            }
            let opening = Task { await self.openNamedLane(name) }
            laneOpenTasks[name] = opening
            return await awaitNamedLane(opening, name: name)
        case .acceptor:
            laneWaiterCounter &+= 1
            let waiterID = laneWaiterCounter
            let lane: any TransportLane = await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(returning: DeadLane(name: name))
                    } else if let existing = lanes[name] {
                        continuation.resume(returning: existing)
                    } else if closedFlag {
                        if TransportDebugLog.enabled {
                            TransportDebugLog.core.notice(
                                """
                                conn \(TransportDebugLog.id(self), privacy: .public) lane \
                                name=\(name, privacy: .public) -> dead lane (closed while waiting)
                                """)
                        }
                        continuation.resume(returning: DeadLane(name: name))
                    } else {
                        if TransportDebugLog.enabled {
                            TransportDebugLog.core.notice(
                                """
                                conn \(TransportDebugLog.id(self), privacy: .public) lane wait \
                                (acceptor) name=\(name, privacy: .public) \
                                waiters=\((self.laneWaiters[name]?.count ?? 0) + 1, privacy: .public)
                                """)
                        }
                        laneWaiters[name, default: []].append(
                            (id: waiterID, continuation: continuation))
                        let sleep = handshakeSleep
                        laneWaiterTasks[waiterID] = Task { [weak self] in
                            do {
                                try await sleep(Self.laneWaitDeadline)
                            } catch {
                                return
                            }
                            guard let self else { return }
                            await self.expireLaneWaiter(name: name, id: waiterID)
                        }
                    }
                }
            }, onCancel: {
                Task { [weak self] in
                    await self?.cancelLaneWaiter(name: name, id: waiterID)
                }
            })
            // A live arrival can race cancellation after the continuation is
            // resumed. Leave the shared lane for an active, single consumer.
            return Task.isCancelled ? DeadLane(name: name) : lane
        }
    }

    /// Resolves one acceptor waiter as a dead lane after the bounded deadline.
    private func expireLaneWaiter(name: String, id: UInt64) {
        guard var waiters = laneWaiters[name],
            let index = waiters.firstIndex(where: { $0.id == id })
        else { return }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            laneWaiters.removeValue(forKey: name)
        } else {
            laneWaiters[name] = waiters
        }
        laneWaiterTasks.removeValue(forKey: id)?.cancel()
        waiter.continuation.resume(returning: DeadLane(name: name))
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                "conn \(TransportDebugLog.id(self), privacy: .public) lane wait expired name=\(name, privacy: .public)")
        }
    }

    /// Removes a cancelled waiter without resuming it twice.
    private func cancelLaneWaiter(name: String, id: UInt64) {
        guard var waiters = laneWaiters[name],
            let index = waiters.firstIndex(where: { $0.id == id })
        else {
            laneWaiterTasks.removeValue(forKey: id)?.cancel()
            return
        }
        let waiter = waiters.remove(at: index)
        if waiters.isEmpty {
            laneWaiters.removeValue(forKey: name)
        } else {
            laneWaiters[name] = waiters
        }
        laneWaiterTasks.removeValue(forKey: id)?.cancel()
        waiter.continuation.resume(returning: DeadLane(name: name))
    }

    /// No sleeps, no drains (Aziz redline 08-19: we can't depend on time).
    /// The reason rides in the QUIC CONNECTION_CLOSE itself, which the
    /// protocol delivers and retransmits during shutdown; stream frames that
    /// lose the race are irrelevant because termination() carries the cause.
    public func closeAll(reason: ConnectionTermination?) async {
        await finishClosure(reason: reason, locallyInitiated: true)
    }

    /// Retires the same owned work on local shutdown and remote stream-source EOF.
    /// A remote close must retain the native peer cause, not write a local one.
    func finishClosure(reason: ConnectionTermination?, locallyInitiated: Bool) async {
        guard !closedFlag else {
            if TransportDebugLog.enabled {
                TransportDebugLog.core.notice(
                    """
                    conn \(TransportDebugLog.id(self), privacy: .public) closeAll ignored \
                    (already closed) reason=\(reason?.code ?? "nil", privacy: .public)
                    """)
            }
            return
        }
        closedFlag = true
        if locallyInitiated {
            localCloseRequested = true
            localTermination = reason
        }
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) closeAll \
                initiator=\(locallyInitiated ? "local" : "remote", privacy: .public) \
                reason=\(reason?.code ?? "nil", privacy: .public) \
                role=\(String(describing: self.role), privacy: .public) \
                remote=\(TransportDebugLog.hex8(self.remoteKey), privacy: .public) \
                openLanes=\(self.lanes.count, privacy: .public) \
                laneWaiters=\(self.laneWaiters.values.reduce(0) { $0 + $1.count }, privacy: .public)
                """)
        }
        acceptLoop?.cancel()
        let openingLanes = Array(laneOpenTasks.values)
        for task in openingLanes { task.cancel() }
        for task in inboundStreamTasks.values { task.cancel() }
        inboundStreamTasks.removeAll()
        rawDeliveryTask?.cancel()
        rawDeliveryTask = nil
        rawDeliveryQueue.removeAll()
        rawDeliveryHead = 0
        pendingRawStreams.removeAll()
        for task in laneWaiterTasks.values { task.cancel() }
        laneWaiterTasks.removeAll()
        let openLanes = Array(lanes.values)
        lanes.removeAll()
        for lane in openLanes {
            await lane.finishSend()
        }
        if locallyInitiated {
            try? connection.close(
                errorCode: reason == nil ? 0 : 1,
                reason: Data((reason?.code ?? "closed").utf8))
        }
        // Close QUIC before joining: native stream opens and writes need that
        // close to unblock; cancelling a Swift task alone cannot interrupt FFI.
        for task in openingLanes { _ = await task.value }
        resumeAllWaitersClosed()
    }

    /// Creates a lane whose end callback returns ownership to this
    /// connection, allowing completed streams to leave the bounded registry.
    func makeLane(name: String, channel: IrohLaneChannel) -> IrohLane {
        let token = UUID()
        return IrohLane(name: name, channel: channel, token: token) { [weak self] in
            await self?.laneEnded(name: name, token: token)
        }
    }

    /// Removes a completed lane only when the callback belongs to the stream
    /// currently registered under that name; a newer stream with the same name
    /// must not be removed by a stale EOF callback.
    private func laneEnded(name: String, token: UUID) {
        guard lanes[name]?.token == token else { return }
        lanes.removeValue(forKey: name)
        if TransportDebugLog.enabled {
            TransportDebugLog.core.notice(
                "conn \(TransportDebugLog.id(self), privacy: .public) lane released name=\(name, privacy: .public) remaining=\(self.lanes.count, privacy: .public)")
        }
    }

    func resumeAllWaitersClosed() {
        if TransportDebugLog.enabled, !laneWaiters.isEmpty {
            TransportDebugLog.core.notice(
                """
                conn \(TransportDebugLog.id(self), privacy: .public) resuming lane waiters as \
                dead lanes lanes=\(self.laneWaiters.keys.joined(separator: ","), privacy: .public) \
                count=\(self.laneWaiters.values.reduce(0) { $0 + $1.count }, privacy: .public)
                """)
        }
        for (name, waiters) in laneWaiters {
            for waiter in waiters {
                laneWaiterTasks.removeValue(forKey: waiter.id)?.cancel()
                waiter.continuation.resume(returning: DeadLane(name: name))
            }
        }
        laneWaiters.removeAll()
        laneWaiterTasks.removeAll()
    }

}
