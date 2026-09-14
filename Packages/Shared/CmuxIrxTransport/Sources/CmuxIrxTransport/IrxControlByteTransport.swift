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

    private let establish: Establish
    private let onClose: OnClose?
    private let closeCode: IrxCloseCode
    private var pair: (IrxConnection, IrxLaneStream)?
    private var lastConnection: IrxConnection?
    private var connectInFlight: Task<(IrxConnection, IrxLaneStream), any Error>?
    private var isClosed = false
    private var controlTerminationObserved = false
    private var closureObservationReadyWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a control-lane transport, optionally releasing its owner claim
    /// when the lane closes.
    public init(
        closeCode: IrxCloseCode,
        establish: @escaping Establish,
        onClose: OnClose? = nil
    ) {
        self.closeCode = closeCode
        self.establish = establish
        self.onClose = onClose
    }

    /// Wraps an already-established pair (host side).
    public init(connection: IrxConnection, control: IrxLaneStream, closeCode: IrxCloseCode) {
        self.init(closeCode: closeCode) { (connection, control) }
    }

    public func connect() async throws {
        _ = try await establishedPair()
    }

    public func receive() async throws -> Data? {
        let (_, lane) = try await establishedPair()
        do {
            let data = try await lane.reader.readRaw()
            if Task.isCancelled {
                await close()
                try Task.checkCancellation()
            }
            if data == nil {
                controlTerminationObserved = true
                await close()
            }
            return data
        } catch {
            if error is CancellationError || Task.isCancelled {
                await close()
                throw error
            }
            controlTerminationObserved = true
            await close()
            throw error
        }
    }

    public func send(_ data: Data) async throws {
        let (_, lane) = try await establishedPair()
        do {
            try await lane.writer.write(data)
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled {
                await close()
                throw error
            }
            controlTerminationObserved = true
            await close()
            throw error
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        resumeClosureObservationReadyWaiters()
        connectInFlight?.cancel()
        connectInFlight = nil
        guard let (connection, lane) = pair else { return }
        pair = nil
        await closeEstablishedPair(connection: connection, lane: lane)
    }

    private func establishedPair() async throws -> (IrxConnection, IrxLaneStream) {
        guard !isClosed else { throw IrxConnectionError.closed(nil) }
        if let pair, await !pair.0.isConnectionClosed() {
            return pair
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

extension IrxControlByteTransport: CmxByteTransportContinuityIdentifying {
    /// Stable per-QUIC-connection identity: the session layer uses this to
    /// tell a surviving transport from a replacement.
    public func transportContinuityID() async -> UInt64? {
        guard let (connection, _) = pair else { return nil }
        return connection.underlying.stableId()
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
