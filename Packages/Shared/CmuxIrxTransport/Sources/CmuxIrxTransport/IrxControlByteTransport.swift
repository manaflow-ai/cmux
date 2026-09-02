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
    public typealias Establish = @Sendable () async throws -> (IrxConnection, IrxLaneStream)

    private let establish: Establish
    private var pair: (IrxConnection, IrxLaneStream)?
    private var connectInFlight: Task<(IrxConnection, IrxLaneStream), any Error>?
    private var isClosed = false

    public init(closeCode: IrxCloseCode, establish: @escaping Establish) {
        _ = closeCode
        self.establish = establish
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
    }

    private func establishedPair() async throws -> (IrxConnection, IrxLaneStream) {
        guard !isClosed else { throw IrxConnectionError.closed(nil) }
        if let pair, await !pair.0.isClosed {
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
            await established.1.close()
            throw IrxConnectionError.closed(nil)
        }
        pair = established
        return established
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
        return CmxTransportClosureObservation {
            _ = await connection.termination()
        }
    }
}
