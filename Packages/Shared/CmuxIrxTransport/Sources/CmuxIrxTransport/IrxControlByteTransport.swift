public import CMUXMobileCore
public import Foundation

/// The control lane as a `CmxByteTransport`, the seam both the Mac host
/// service and the iOS RPC session consume. Raw passthrough: the payload is
/// the app's own MobileSyncFrameCodec frames, untouched.
///
/// `establish` supplies the admitted (connection, control-lane) pair: the Mac
/// wraps an already-admitted session; the iOS side dials through its peer
/// engine. `closeCode` is retained in the construction API for callers that
/// classify lane teardown, but this lane never closes the shared QUIC session.
/// Session ownership belongs to ``IrxPeerEngine``.
public actor IrxControlByteTransport: CmxByteTransport {
    /// Factory for an admitted connection and its control lane.
    public typealias Establish = @Sendable () async throws -> (IrxConnection, IrxLaneStream)
    /// Closure called after this lane releases its owner claim.
    public typealias OnClose = @Sendable () async -> Void

    private let establish: Establish
    private let onClose: OnClose?
    private var pair: (IrxConnection, IrxLaneStream)?
    private var lastConnection: IrxConnection?
    private var connectInFlight: Task<(IrxConnection, IrxLaneStream), any Error>?
    private var isClosed = false
    private var closureObservationReadyWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a control-lane transport, optionally releasing its owner claim
    /// when the lane closes.
    public init(
        closeCode: IrxCloseCode,
        establish: @escaping Establish,
        onClose: OnClose? = nil
    ) {
        _ = closeCode
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
        return try await lane.reader.readRaw()
    }

    public func send(_ data: Data) async throws {
        let (_, lane) = try await establishedPair()
        try await lane.writer.write(data)
    }

    public func close() async {
        isClosed = true
        resumeClosureObservationReadyWaiters()
        connectInFlight?.cancel()
        connectInFlight = nil
        guard let (_, lane) = pair else { return }
        pair = nil
        // This is an RPC-lane teardown, not a session teardown. The QUIC
        // connection is owned by IrxPeerEngine and may still carry the
        // keepalive, event, and terminal lanes. Closing it here made a
        // retiring RPC client look like a peer death to the engine.
        await lane.writer.finish()
        await lane.reader.stop()
        await onClose?()
    }

    private func establishedPair() async throws -> (IrxConnection, IrxLaneStream) {
        guard !isClosed else { throw IrxConnectionError.closed(nil) }
        if let pair, await !pair.0.isConnectionClosed() {
            return pair
        }
        if let connectInFlight {
            return try await connectInFlight.value
        }
        let task = Task<(IrxConnection, IrxLaneStream), any Error> {
            try await self.establish()
        }
        connectInFlight = task
        defer { connectInFlight = nil }
        let established = try await task.value
        guard !isClosed else {
            lastConnection = established.0
            await established.1.close()
            await onClose?()
            throw IrxConnectionError.closed(nil)
        }
        lastConnection = established.0
        pair = established
        resumeClosureObservationReadyWaiters()
        return established
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
    /// A control-lane failure is not proof that the shared QUIC session died.
    /// Read the session snapshot directly so application-level liveness can
    /// repair this lane without redialing every other lane.
    public func isTransportClosed() async -> Bool {
        if isClosed { return true }
        guard let connection = pair?.0 ?? lastConnection else { return false }
        return await connection.isConnectionClosed()
    }
}
