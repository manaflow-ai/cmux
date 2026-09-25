public import CMUXMobileCore
public import Foundation

/// The control lane as a `CmxByteTransport`, the seam both the Mac host
/// service and the iOS RPC session consume. Raw passthrough: the payload is
/// the app's own MobileSyncFrameCodec frames, untouched.
///
/// `establish` supplies the admitted (connection, control-lane) pair: the Mac
/// wraps an already-admitted session; the iOS side dials through its peer
/// engine. Closing the control lane is terminal for the RPC owner's admitted
/// session, so the transport retires that exact session before closing the
/// complete QUIC connection. Session ownership belongs to
/// ``IrxPeerEngine``.
///
/// Each transport binds to at most one admitted session. Native closure makes
/// that transport terminal; the RPC owner creates a new transport to recover.
///
/// The control lane itself is replaceable: when its stream goes silent while
/// the connection underneath still carries other lanes, the client opens a
/// ``IrxLaneKind/controlRepair`` stream on the same connection and both ends
/// move the lane onto it (``repairControlStream(silentSince:)`` and
/// ``acceptControlLaneReplacement(_:)``). Reads are delivered on whole
/// `MobileSyncFrameCodec` frame boundaries so a frame cut off by a
/// replacement is dropped with its stream instead of corrupting the
/// consumer's decoder.
public actor IrxControlByteTransport: CmxByteTransport {
    /// Factory for an admitted connection and its control lane.
    public typealias Establish = @Sendable () async throws -> (IrxConnection, IrxLaneStream)
    /// Closure called when this transport releases its owner claim.
    ///
    /// `closeCode` identifies the termination that caused the release.
    /// `retiresConnection` is true when this transport initiated a local
    /// owner retirement while the admitted connection was still live. A
    /// A genuine control EOF or read/write failure is reported as a remote
    /// host shutdown, so the peer engine's native termination watcher remains
    /// responsible for automatic recovery. Caller cancellation remains a
    /// local owner retirement.
    public typealias OnClose = @Sendable (
        _ connection: IrxConnection,
        _ closeCode: IrxCloseCode,
        _ retiresConnection: Bool
    ) async -> Void

    private enum LaneReadOutcome {
        case data(Data)
        case finished
        case failed(any Error)
        case replaced
        case closed
        case cancelled
    }

    private struct LaneRead {
        let generation: UInt64
        var result: Result<Data?, any Error>?
    }

    private struct ReadWaiter {
        let id: UUID
        let continuation: CheckedContinuation<LaneReadOutcome, Never>
    }

    private let establish: Establish
    private let onClose: OnClose?
    private let permitsIO: @Sendable () async -> Bool
    private let closeCode: IrxCloseCode
    private let controlRepairDeadline: Duration
    private var pair: (IrxConnection, IrxLaneStream)?
    private var lastConnection: IrxConnection?
    private var connectInFlight: Task<(IrxConnection, IrxLaneStream), any Error>?
    private var isClosed = false
    private var controlTerminationObserved = false
    private var closureObservationReadyWaiters: [CheckedContinuation<Void, Never>] = []
    /// Increments each time a replacement stream takes over the control lane.
    private var laneGeneration: UInt64 = 0
    /// Bytes from the current stream that do not yet complete a frame.
    private var inboundPartialFrame = Data()
    /// The one native read in flight on the current stream. A native read
    /// ignores task cancellation, so it runs detached from `receive()` and a
    /// replaced stream's read is simply abandoned.
    private var laneRead: LaneRead?
    private var readWaiter: ReadWaiter?
    /// While a replacement is being negotiated, a failure on the stream it is
    /// replacing is expected (the peer retires it) and must not terminate the
    /// session until the replacement settles.
    private var laneReplacementInProgress = false
    private var laneReplacementWaiters: [CheckedContinuation<Void, Never>] = []
    /// Identifies the client replacement attempt allowed to install its
    /// stream. Cleared when the attempt's deadline passes, so a late
    /// acknowledgement cannot install a stream nobody is waiting for.
    private var controlRepairAttempt: UUID?

    /// Creates a control-lane transport, optionally releasing its owner claim
    /// when the lane closes.
    ///
    /// - Parameters:
    ///   - closeCode: Local termination reason when the owner closes the transport.
    ///   - establish: Factory returning an admitted connection and control lane.
    ///   - onClose: Optional callback releasing the connection's owner claim.
    ///   - permitsIO: Revalidates the account and lease before each write. Refusal
    ///     closes the transport before it sends bytes. Defaults to unrestricted
    ///     writes for callers that enforce authorization at their RPC boundary.
    ///   - controlRepairDeadline: How long a control-stream replacement may
    ///     take to be acknowledged by the host.
    public init(
        closeCode: IrxCloseCode,
        establish: @escaping Establish,
        onClose: OnClose? = nil,
        permitsIO: @escaping @Sendable () async -> Bool = { true },
        controlRepairDeadline: Duration = IrxProtocol().controlRepairDeadline
    ) {
        self.closeCode = closeCode
        self.establish = establish
        self.onClose = onClose
        self.permitsIO = permitsIO
        self.controlRepairDeadline = controlRepairDeadline
    }

    /// Wraps an already-established pair (host side).
    public init(connection: IrxConnection, control: IrxLaneStream, closeCode: IrxCloseCode) {
        self.init(closeCode: closeCode) { (connection, control) }
    }

    public func connect() async throws {
        _ = try await establishedPair()
    }

    /// Returns one or more whole frames, or nil once the control lane ends.
    /// Single consumer: at most one `receive()` may be outstanding.
    public func receive() async throws -> Data? {
        while true {
            if let frames = takeCompleteFrames() { return frames }
            let (_, lane) = try await establishedPair()
            let generation = laneGeneration
            switch await nextLaneRead(lane: lane, generation: generation) {
            case .replaced:
                continue
            case .closed:
                throw IrxConnectionError.closed(nil)
            case .cancelled:
                await close()
                throw CancellationError()
            case .data(let chunk):
                if Task.isCancelled {
                    await close()
                    throw CancellationError()
                }
                guard generation == laneGeneration else { continue }
                inboundPartialFrame.append(chunk)
            case .finished:
                if Task.isCancelled {
                    await close()
                    throw CancellationError()
                }
                if await laneWasReplaced(since: generation) { continue }
                controlTerminationObserved = true
                await close()
                return nil
            case .failed(let error):
                if error is CancellationError || Task.isCancelled {
                    await close()
                    throw error
                }
                if await laneWasReplaced(since: generation) { continue }
                controlTerminationObserved = true
                await close()
                throw error
            }
        }
    }

    public func send(_ data: Data) async throws {
        _ = try await sendReportingControlStreamGeneration(data)
    }

    public func sendReportingControlStreamGeneration(_ data: Data) async throws -> UInt64 {
        while true {
            let (_, lane) = try await establishedPair()
            let generation = laneGeneration
            guard await permitsIO(), !isClosed else {
                await close()
                throw IrxConnectionError.closed(nil)
            }
            // The authorization check can suspend across a replacement.
            guard generation == laneGeneration else { continue }
            do {
                try await lane.writer.write(data)
                try Task.checkCancellation()
                return generation
            } catch {
                if error is CancellationError || Task.isCancelled {
                    await close()
                    throw error
                }
                // A replaced stream is reset as it retires. The peer drops
                // partial frames with that stream, so the whole frame is
                // written again on the replacement.
                if await laneWasReplaced(since: generation) { continue }
                controlTerminationObserved = true
                await close()
                throw error
            }
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        resumeClosureObservationReadyWaiters()
        resumeReadWaiter(with: .closed)
        finishLaneReplacement()
        connectInFlight?.cancel()
        connectInFlight = nil
        guard let (connection, lane) = pair else { return }
        pair = nil
        await closeEstablishedPair(connection: connection, lane: lane)
    }

    // MARK: - Control-stream replacement

    /// Host side: moves this admitted session's control lane onto a
    /// client-opened ``IrxLaneKind/controlRepair`` stream, then acknowledges
    /// it. Returns false, resetting the stream, when there is no live session
    /// to move.
    @discardableResult
    public func acceptControlLaneReplacement(_ lane: IrxLaneStream) async -> Bool {
        guard !isClosed, !laneReplacementInProgress, let (connection, _) = pair else {
            Self.retire(lane)
            return false
        }
        laneReplacementInProgress = true
        defer { finishLaneReplacement() }
        do {
            // Acknowledge before switching, so the ack is the first frame on
            // the new stream and nothing written for the session precedes it.
            try await lane.writer.writeControlFrame(IrxControlLaneRepairAck())
        } catch {
            Self.retire(lane)
            return false
        }
        guard !isClosed, let current = pair, current.0 === connection else {
            Self.retire(lane)
            return false
        }
        installReplacementLane(lane, on: connection)
        return true
    }

    private func adoptReplacementLane(
        _ lane: IrxLaneStream,
        on connection: IrxConnection,
        attempt: UUID
    ) -> UInt64? {
        guard controlRepairAttempt == attempt,
              !isClosed,
              let current = pair,
              current.0 === connection else {
            Self.retire(lane)
            return nil
        }
        installReplacementLane(lane, on: connection)
        return laneGeneration
    }

    private func installReplacementLane(_ lane: IrxLaneStream, on connection: IrxConnection) {
        let retired = pair?.1
        pair = (connection, lane)
        laneGeneration &+= 1
        inboundPartialFrame = Data()
        laneRead = nil
        resumeReadWaiter(with: .replaced)
        if let retired { Self.retire(retired) }
    }

    private func finishLaneReplacement() {
        laneReplacementInProgress = false
        let waiters = laneReplacementWaiters
        laneReplacementWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// Whether the stream this I/O used has been, or is about to be, replaced.
    private func laneWasReplaced(since generation: UInt64) async -> Bool {
        if generation != laneGeneration { return true }
        guard laneReplacementInProgress else { return false }
        await withCheckedContinuation { laneReplacementWaiters.append($0) }
        return generation != laneGeneration
    }

    /// Resets both halves of a stream retired by a replacement. Separate tasks,
    /// because a native write or read still parked on it holds that half's
    /// lock and must not keep the other half open.
    private nonisolated static func retire(_ lane: IrxLaneStream) {
        let code = IrxProtocol().retiredControlStreamErrorCode
        Task { await lane.writer.reset(errorCode: code) }
        Task { await lane.reader.stop(errorCode: code) }
    }

    // MARK: - Reads

    private func nextLaneRead(lane: IrxLaneStream, generation: UInt64) async -> LaneReadOutcome {
        if let read = laneRead, read.generation == generation, let result = read.result {
            laneRead = nil
            return Self.outcome(of: result)
        }
        if laneRead?.generation != generation {
            // Never start a native read for a cancelled caller: it cannot be
            // interrupted, and its stream lock would hold up close().
            if Task.isCancelled { return .cancelled }
            laneRead = LaneRead(generation: generation, result: nil)
            let reader = lane.reader
            Task { [weak self] in
                let result: Result<Data?, any Error>
                do {
                    result = .success(try await reader.readRaw())
                } catch {
                    result = .failure(error)
                }
                await self?.laneReadDidFinish(generation: generation, result: result)
            }
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else if isClosed {
                    continuation.resume(returning: .closed)
                } else if generation != laneGeneration {
                    continuation.resume(returning: .replaced)
                } else if let read = laneRead, read.generation == generation,
                          let result = read.result {
                    laneRead = nil
                    continuation.resume(returning: Self.outcome(of: result))
                } else {
                    resumeReadWaiter(with: .replaced)
                    readWaiter = ReadWaiter(id: waiterID, continuation: continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelReadWaiter(id: waiterID) }
        }
    }

    private func laneReadDidFinish(generation: UInt64, result: Result<Data?, any Error>) {
        // A replaced stream's late read is dropped with its stream.
        guard generation == laneGeneration, laneRead?.generation == generation else { return }
        if let waiter = readWaiter {
            readWaiter = nil
            laneRead = nil
            waiter.continuation.resume(returning: Self.outcome(of: result))
        } else {
            laneRead?.result = result
        }
    }

    private func cancelReadWaiter(id: UUID) {
        guard readWaiter?.id == id else { return }
        resumeReadWaiter(with: .cancelled)
    }

    private func resumeReadWaiter(with outcome: LaneReadOutcome) {
        guard let waiter = readWaiter else { return }
        readWaiter = nil
        waiter.continuation.resume(returning: outcome)
    }

    private static func outcome(of result: Result<Data?, any Error>) -> LaneReadOutcome {
        switch result {
        case .success(let data?):
            return .data(data)
        case .success(nil):
            return .finished
        case .failure(let error):
            return .failed(error)
        }
    }

    /// Splits off the longest prefix of whole frames. A header announcing a
    /// frame larger than the codec allows is not something this lane can
    /// align, so everything is handed over for the consumer's decoder to
    /// reject exactly as before.
    private func takeCompleteFrames() -> Data? {
        let buffered = inboundPartialFrame
        guard !buffered.isEmpty else { return nil }
        let headerByteCount = MobileSyncFrameCodec.headerByteCount
        var boundary = 0
        while buffered.count - boundary >= headerByteCount {
            let headerStart = buffered.startIndex + boundary
            var length = 0
            for byte in buffered[headerStart..<(headerStart + headerByteCount)] {
                length = (length << 8) | Int(byte)
            }
            guard length <= MobileSyncFrameCodec.defaultMaximumFrameByteCount else {
                inboundPartialFrame = Data()
                return buffered
            }
            guard buffered.count - boundary - headerByteCount >= length else { break }
            boundary += headerByteCount + length
        }
        guard boundary > 0 else { return nil }
        if boundary == buffered.count {
            inboundPartialFrame = Data()
            return buffered
        }
        let split = buffered.startIndex + boundary
        inboundPartialFrame = Data(buffered[split...])
        return Data(buffered[buffered.startIndex..<split])
    }

    // MARK: - Establishment

    private func establishedPair() async throws -> (IrxConnection, IrxLaneStream) {
        guard !isClosed else { throw IrxConnectionError.closed(nil) }
        if let pair {
            let connectionIsClosed = await pair.0.isConnectionClosed()
            guard !isClosed else { throw IrxConnectionError.closed(nil) }
            if connectionIsClosed {
                // Reads and writes may still be unwinding on this pair. Keep
                // their eventual close tied to this RPC generation's session.
                await close()
                throw IrxConnectionError.closed(nil)
            }
            // A replacement may have installed while this call suspended.
            return self.pair ?? pair
        }
        if let connectInFlight {
            let established = try await connectInFlight.value
            guard !isClosed else { throw IrxConnectionError.closed(nil) }
            return established
        }
        let task = Task<(IrxConnection, IrxLaneStream), any Error> {
            try await self.establish()
        }
        connectInFlight = task
        defer { connectInFlight = nil }
        let established = try await task.value
        guard !isClosed else {
            lastConnection = established.0
            await closeEstablishedPair(
                connection: established.0,
                lane: established.1
            )
            throw IrxConnectionError.closed(nil)
        }
        lastConnection = established.0
        pair = established
        resumeClosureObservationReadyWaiters()
        return established
    }

    private func closeEstablishedPair(
        connection: IrxConnection,
        lane: IrxLaneStream
    ) async {
        let connectionWasAlreadyClosed = await connection.isConnectionClosed()
        let retiresConnection = !controlTerminationObserved
            && !connectionWasAlreadyClosed
        let terminationCode: IrxCloseCode =
            controlTerminationObserved ? .hostShutdown : closeCode
        if !retiresConnection, !connectionWasAlreadyClosed {
            // A finished control lane is the peer's session termination
            // signal. Close the complete connection before releasing the lane
            // claim, so a replacement cannot attach to this dead stream.
            await connection.close(code: terminationCode, origin: .remote)
        }
        await onClose?(connection, terminationCode, retiresConnection)
        await lane.writer.finish()
        await lane.reader.stop()
        if retiresConnection {
            await connection.close(code: closeCode, origin: .local)
        }
    }

    private func resumeClosureObservationReadyWaiters() {
        let waiters = closureObservationReadyWaiters
        closureObservationReadyWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }
}

extension IrxControlByteTransport: CmxByteTransportControlStreamRepairing {
    /// Client side: replaces a silent control stream with a fresh stream on the
    /// same connection.
    ///
    /// Evidence, strongest first:
    /// - The host's application layer acknowledges the fresh stream within
    ///   the repair deadline: the lane moves onto it (`repaired`).
    /// - The host resets or finishes the fresh stream while the connection
    ///   stays open (an older host, or a session it no longer serves): the
    ///   connection demonstrably carried that answer (`unavailable`).
    /// - No answer by the deadline: `connectionSilent` only when the
    ///   connection has closed or has positive evidence of whole-connection
    ///   silence since `silentSince`; otherwise `unavailable`.
    public func repairControlStream(
        silentSince: ContinuousClock.Instant
    ) async -> CmxControlStreamRepairOutcome {
        guard !isClosed, !laneReplacementInProgress, let (connection, _) = pair else {
            return .unavailable
        }
        if await connection.isConnectionClosed() { return .connectionSilent }
        guard !isClosed, !laneReplacementInProgress, let current = pair,
              current.0 === connection else {
            return .unavailable
        }
        laneReplacementInProgress = true
        defer { finishLaneReplacement() }
        let attempt = UUID()
        controlRepairAttempt = attempt
        let startGeneration = laneGeneration
        let result: IrxDeadlineResult<UInt64>
        do {
            result = try await withIrxDeadlineResult(controlRepairDeadline) { [self] in
                let lane = try await connection.openLane(IrxLaneDescriptor(lane: .controlRepair))
                let ack: IrxControlLaneRepairAck?
                do {
                    ack = try await lane.reader.readControlFrame(IrxControlLaneRepairAck.self)
                } catch {
                    Self.retire(lane)
                    throw error
                }
                guard ack != nil else {
                    Self.retire(lane)
                    throw IrxFrameCodecError.unexpectedEOF
                }
                return await adoptReplacementLane(lane, on: connection, attempt: attempt)
            }
        } catch {
            result = .operation(nil)
        }
        // A late acknowledgement must not install a stream nobody waits for.
        controlRepairAttempt = nil
        if laneGeneration != startGeneration, !isClosed {
            return .repaired(generation: laneGeneration)
        }
        if case .operation = result {
            return await connection.isConnectionClosed() ? .connectionSilent : .unavailable
        }
        switch await connection.applicationSilenceEvidence(since: silentSince) {
        case .silent:
            return .connectionSilent
        case .activity, .inconclusive:
            return .unavailable
        }
    }
}

extension IrxControlByteTransport: CmxByteTransportContinuityIdentifying {
    /// Stable per-QUIC-connection identity: the session layer uses this to
    /// tell a surviving transport from a replacement.
    public func transportContinuityID() async -> UInt64? {
        guard let (connection, _) = pair else { return nil }
        return connection.underlying.stableId()
    }
}

extension IrxControlByteTransport: CmxByteTransportConnectionInspecting {
    public func transportConnectionObservation() async -> CmxTransportConnectionObservation? {
        guard !isClosed, let (connection, _) = pair else { return nil }
        let selected = connection.underlying.paths().first(where: { $0.isSelected })
        return CmxTransportConnectionObservation(
            continuityID: connection.underlying.stableId(),
            pathKind: selected.map { $0.isRelay ? .relay : .direct } ?? .unknown
        )
    }
}

extension IrxControlByteTransport: CmxByteTransportClosureObserving {
    /// Resolves when the underlying connection ends, letting the app react to
    /// death immediately instead of discovering it on the next failed write.
    public func transportClosureObservation() async -> CmxTransportClosureObservation? {
        guard let (connection, _) = pair else { return nil }
        let observationID = await connection.makeClosureObservationID()
        return CmxTransportClosureObservation(waitUntilClosed: {
            await connection.waitForClosure(observationID: observationID)
        }, cancel: {
            Task { await connection.cancelClosureObservation(observationID: observationID) }
        })
    }
}

extension IrxControlByteTransport: CmxByteTransportClosureObservationReadiness {
    public func waitUntilTransportClosureObservationIsReady() async -> Bool {
        guard pair == nil, !isClosed else { return pair != nil }
        await withCheckedContinuation { continuation in
            if pair != nil || isClosed {
                continuation.resume()
            } else {
                closureObservationReadyWaiters.append(continuation)
            }
        }
        return pair != nil
    }
}

extension IrxControlByteTransport: CmxByteTransportLivenessObserving {
    /// A control-lane failure terminates the admitted session. Read the
    /// complete connection snapshot so callers can distinguish that terminal
    /// state from a transport that has not been established yet.
    public func isTransportClosed() async -> Bool {
        if isClosed { return true }
        guard let connection = pair?.0 ?? lastConnection else { return false }
        return await connection.isConnectionClosed()
    }
}
