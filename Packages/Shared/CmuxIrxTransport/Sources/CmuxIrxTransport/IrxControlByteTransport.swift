public import CMUXMobileCore
public import Foundation

/// The control lane as a `CmxByteTransport`, the seam both the Mac host
/// service and the iOS RPC session consume. Raw passthrough: the payload is
/// the app's own MobileSyncFrameCodec frames, untouched.
///
/// `establish` supplies the admitted (connection, control-lane) pair: the Mac
/// wraps an already-admitted session; the iOS side dials through its peer
/// engine. `closeCode` attributes the QUIC close when the app layer closes
/// this transport (`explicit-redial` on iOS keeps the engine's auto-redial
/// armed for the replacement client; a denial would park it instead).
public actor IrxControlByteTransport: CmxByteTransport {
    public typealias Establish = @Sendable () async throws -> (IrxConnection, IrxLaneStream)

    private let establish: Establish
    private let closeCode: IrxCloseCode
    private var pair: (IrxConnection, IrxLaneStream)?
    private var connectInFlight: Task<(IrxConnection, IrxLaneStream), any Error>?

    public init(closeCode: IrxCloseCode, establish: @escaping Establish) {
        self.closeCode = closeCode
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
        guard let (connection, lane) = pair else { return }
        pair = nil
        await lane.writer.finish()
        await connection.close(code: closeCode, origin: .local)
    }

    private func establishedPair() async throws -> (IrxConnection, IrxLaneStream) {
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
