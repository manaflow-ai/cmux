public import CMUXMobileCore
public import Foundation

/// An admitted multistream client session over one Iroh QUIC connection.
public actor CmxIrohClientSession {
    public typealias PrivateFallbackContextProvider = @Sendable () async throws -> CmxIrohClientContext

    private let endpoint: any CmxIrohEndpoint
    private let targetIdentity: CmxIrohPeerIdentity
    private let dialPlan: CmxIrohDialPlan
    private let credential: CmxIrohAdmissionCredential
    private let privateFallbackAuthorization: CmxIrohPrivateFallbackAuthorization?
    private let privateFallbackValidator: (any CmxIrohPrivateFallbackValidating)?
    private let privateFallbackContextProvider: PrivateFallbackContextProvider?
    private let protocolConfiguration: CmxIrohProtocolConfiguration
    private let headerCodec: CmxIrohStreamHeaderCodec
    private let admissionCodec = CmxIrohAdmissionAckCodec()
    private var connectionTask: Task<CmxIrohConnectedControl, any Error>?
    private var connection: (any CmxIrohConnection)?
    private var controlStream: CmxIrohBidirectionalStream?
    private var serverEventReceiver: CmxIrohClientServerEventReceiver?
    private var controlReceiveBuffer = Data()
    private var closed = false

    /// Creates a disconnected session with an explicit two-phase dial plan.
    ///
    /// - Parameters:
    ///   - endpoint: The active local endpoint generation.
    ///   - targetIdentity: The exact remote EndpointID expected from QUIC TLS.
    ///   - dialPlan: Public paths followed by profile-gated private fallback paths.
    ///   - credential: The backend grant or same-account offline pairing proof.
    ///   - privateFallbackAuthorization: The generation snapshot that admitted
    ///     the plan's private hints.
    ///   - privateFallbackValidator: The provider that can re-read current
    ///     network state immediately before a private dial.
    ///   - protocolConfiguration: The ALPN and stream-header limit.
    /// - Throws: A stream-codec configuration error.
    public init(
        endpoint: any CmxIrohEndpoint,
        targetIdentity: CmxIrohPeerIdentity,
        dialPlan: CmxIrohDialPlan,
        credential: CmxIrohAdmissionCredential,
        privateFallbackAuthorization: CmxIrohPrivateFallbackAuthorization? = nil,
        privateFallbackValidator: (any CmxIrohPrivateFallbackValidating)? = nil,
        privateFallbackContextProvider: PrivateFallbackContextProvider? = nil,
        protocolConfiguration: CmxIrohProtocolConfiguration = .cmuxMobileV1
    ) throws {
        self.endpoint = endpoint
        self.targetIdentity = targetIdentity
        self.dialPlan = dialPlan
        self.credential = credential
        self.privateFallbackAuthorization = privateFallbackAuthorization
        self.privateFallbackValidator = privateFallbackValidator
        self.privateFallbackContextProvider = privateFallbackContextProvider
        self.protocolConfiguration = protocolConfiguration
        headerCodec = try CmxIrohStreamHeaderCodec(configuration: protocolConfiguration)
    }

    /// Establishes and admits the control stream, coalescing concurrent callers.
    ///
    /// - Throws: A transport, framing, identity, admission, or cancellation error.
    public func connect() async throws {
        guard !closed else { throw CmxIrohClientSessionError.alreadyClosed }
        if connection != nil, controlStream != nil { return }

        let task: Task<CmxIrohConnectedControl, any Error>
        if let connectionTask {
            task = connectionTask
        } else {
            task = Task { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.establishConnection()
            }
            connectionTask = task
        }

        do {
            let connected = try await withTaskCancellationHandler(operation: {
                try await task.value
            }, onCancel: {
                task.cancel()
            })
            if connection == nil, controlStream == nil {
                connection = connected.connection
                controlStream = connected.stream
                controlReceiveBuffer = connected.initialReceiveBuffer
            }
            connectionTask = nil
        } catch {
            connectionTask = nil
            throw error
        }
    }

    /// Reads control-lane bytes after admission framing has been removed.
    ///
    /// - Parameter maximumByteCount: The positive per-read cap.
    /// - Returns: Application bytes, or `nil` after clean peer finish.
    /// - Throws: A transport or lifecycle error.
    public func receiveControl(
        maximumByteCount: Int = 64 * 1_024
    ) async throws -> Data? {
        guard maximumByteCount > 0 else {
            throw CmxIrohClientSessionError.invalidMaximumByteCount(maximumByteCount)
        }
        guard !closed else { throw CmxIrohClientSessionError.alreadyClosed }
        guard let controlStream else { throw CmxIrohClientSessionError.notConnected }
        if !controlReceiveBuffer.isEmpty {
            let count = min(maximumByteCount, controlReceiveBuffer.count)
            let value = Data(controlReceiveBuffer.prefix(count))
            controlReceiveBuffer.removeFirst(count)
            return value
        }
        return try await controlStream.receiveStream.receive(
            maximumByteCount: maximumByteCount
        )
    }

    /// Writes application bytes on the admitted control lane.
    ///
    /// - Parameter data: The complete buffer to send.
    /// - Throws: A transport or lifecycle error.
    public func sendControl(_ data: Data) async throws {
        guard !closed else { throw CmxIrohClientSessionError.alreadyClosed }
        guard let controlStream else { throw CmxIrohClientSessionError.notConnected }
        try await controlStream.sendStream.send(data)
    }

    /// Opens a terminal or artifact bidirectional lane on the admitted connection.
    ///
    /// - Parameters:
    ///   - lane: A terminal or artifact lane declaration.
    ///   - priority: The Iroh relative stream priority selected by the caller.
    /// - Returns: The stream after its lane header has been written.
    /// - Throws: A transport, framing, or lifecycle error.
    public func openBidirectionalLane(
        _ lane: CmxIrohLane,
        priority: Int32
    ) async throws -> CmxIrohBidirectionalStream {
        switch lane {
        case .terminal, .artifact:
            break
        case .control, .serverEvents:
            throw CmxIrohClientSessionError.invalidOutgoingLane
        }
        guard !closed else { throw CmxIrohClientSessionError.alreadyClosed }
        guard let connection else { throw CmxIrohClientSessionError.notConnected }
        guard protocolConfiguration.maximumConcurrentClientApplicationLaneCount > 0 else {
            throw CmxIrohClientSessionError.applicationLanesUnavailable
        }
        let stream = try await connection.openBidirectionalStream()
        do {
            try await stream.sendStream.setPriority(priority)
            let header = try CmxIrohStreamHeader(lane: lane)
            try await stream.sendStream.send(headerCodec.encode(header))
            return stream
        } catch {
            await stream.sendStream.reset(errorCode: 1)
            await stream.receiveStream.stop(errorCode: 1)
            throw error
        }
    }

    /// Starts the session-owned server-event accept loop. This is the only API
    /// that can grant peer-created unidirectional stream credit, so feature
    /// consumers cannot race over QUIC stream acceptance.
    public func serverEventByteStream() async throws -> CmxIndependentEventByteStream {
        guard !closed else { throw CmxIrohClientSessionError.alreadyClosed }
        guard let connection else { throw CmxIrohClientSessionError.notConnected }
        let receiver: CmxIrohClientServerEventReceiver
        if let serverEventReceiver {
            receiver = serverEventReceiver
        } else {
            receiver = try CmxIrohClientServerEventReceiver(
                connection: connection,
                protocolConfiguration: protocolConfiguration
            )
            serverEventReceiver = receiver
        }
        return try await receiver.byteStream()
    }

    /// Suspends until the exact admitted QUIC connection closes.
    ///
    /// The session pool uses this independently of control-lane I/O so a peer or
    /// suspended-iOS timeout evicts the stale pooled session before the next RPC.
    public func waitUntilClosed() async {
        guard let connection else { return }
        await connection.waitUntilClosed()
    }

    /// Returns whether the admitted QUIC connection already closed.
    ///
    /// This closes the scheduler gap between Iroh publishing its close reason
    /// and the pool's independent closure watcher evicting this session.
    func isClosed() async -> Bool {
        if closed { return true }
        guard let connection else { return false }
        return await connection.isClosed()
    }

    /// Returns Iroh's process-local identity for this exact admitted QUIC
    /// connection. Alternate endpoint implementations may not provide one.
    func connectionContinuityID() async -> UInt64? {
        guard !closed,
              let connection,
              let continuityConnection = connection as? any CmxIrohConnectionContinuityIdentifying else {
            return nil
        }
        guard !(await connection.isClosed()) else { return nil }
        return await continuityConnection.connectionContinuityID()
    }

    /// Reads package-private path evidence from the exact admitted connection.
    func observedSelectedPath() async -> CmxIrohObservedConnectionPath {
        guard let connection = connection as? any CmxIrohConnectionPathInspecting else {
            return .unavailable
        }
        return await connection.observedSelectedPath()
    }

    /// Observes path-selection changes without exposing transport coordinates.
    func observedSelectedPathChanges() async -> AsyncStream<CmxIrohObservedConnectionPath> {
        guard let connection = connection as? any CmxIrohConnectionPathInspecting else {
            return AsyncStream { continuation in
                continuation.yield(.unavailable)
                continuation.finish()
            }
        }
        return await connection.observedSelectedPathChanges()
    }

    /// Closes the control stream and complete QUIC connection.
    public func close() async {
        guard !closed else { return }
        closed = true
        connectionTask?.cancel()
        connectionTask = nil
        await serverEventReceiver?.close()
        serverEventReceiver = nil
        if let controlStream {
            await controlStream.sendStream.reset(errorCode: 0)
            await controlStream.receiveStream.stop(errorCode: 0)
        }
        if let connection {
            await connection.close(errorCode: 0, reason: "client_closed")
        }
        controlStream = nil
        self.connection = nil
        controlReceiveBuffer.removeAll(keepingCapacity: false)
    }

    private func establishConnection() async throws -> CmxIrohConnectedControl {
        var establishedConnection: (any CmxIrohConnection)?
        var publicConnectionError: (any Error)?
        if !dialPlan.publicPaths.isEmpty {
            do {
                establishedConnection = try await endpoint.connect(
                    to: CmxIrohEndpointAddress(
                        identity: targetIdentity,
                        pathHints: dialPlan.publicPaths
                    ),
                    alpn: protocolConfiguration.alpn
                )
            } catch {
                try Task.checkCancellation()
                publicConnectionError = error
            }
        }
        if establishedConnection == nil {
            let fallbackContext: CmxIrohClientContext
            if let privateFallbackContextProvider {
                fallbackContext = try await privateFallbackContextProvider()
                guard fallbackContext.credential == credential,
                      fallbackContext.dialPlan.publicPaths == dialPlan.publicPaths else {
                    throw CmxIrohPrivateFallbackValidationError.authorizationMismatch
                }
            } else {
                fallbackContext = CmxIrohClientContext(
                    dialPlan: dialPlan,
                    credential: credential,
                    privateFallbackAuthorization: privateFallbackAuthorization
                )
            }
            let fallbackPaths = fallbackContext.dialPlan.privateFallbackPaths
            guard !fallbackPaths.isEmpty else {
                if let publicConnectionError { throw publicConnectionError }
                throw CmxIrohRegistryContextError.dialPlanUnavailable
            }
            guard let privateFallbackValidator else {
                throw CmxIrohPrivateFallbackValidationError.unavailable
            }
            guard let authorization = fallbackContext.privateFallbackAuthorization,
                  authorization.pathHints == fallbackPaths else {
                throw CmxIrohPrivateFallbackValidationError.authorizationMismatch
            }
            try await privateFallbackValidator.validatePrivateFallback(
                authorization
            )
            try Task.checkCancellation()
            establishedConnection = try await endpoint.connect(
                to: CmxIrohEndpointAddress(
                    identity: targetIdentity,
                    pathHints: fallbackPaths
                ),
                alpn: protocolConfiguration.alpn
            )
        }
        guard let establishedConnection else {
            throw CmxIrohRegistryContextError.dialPlanUnavailable
        }

        do {
            try Task.checkCancellation()
            guard await establishedConnection.remoteIdentity() == targetIdentity else {
                throw CmxIrohClientSessionError.remoteIdentityMismatch
            }
            try await establishedConnection.setIncomingStreamLimits(
                maximumBidirectionalStreamCount: 0,
                maximumUnidirectionalStreamCount: 0
            )
            let stream = try await establishedConnection.openBidirectionalStream()
            let header = try CmxIrohStreamHeader(
                lane: .control,
                credential: credential
            )
            try await stream.sendStream.send(headerCodec.encode(header))
            let admission = try await readAdmissionFrame(from: stream.receiveStream)
            switch admission.frame {
            case .acceptedPendingNatTraversal, .acceptedRelayOnly:
                if admission.frame == .acceptedPendingNatTraversal {
                    try Task.checkCancellation()
                    try await establishedConnection.authorizeNatTraversal()
                }
                try Task.checkCancellation()
                try await stream.sendStream.send(
                    admissionCodec.encodeFrame(.clientReady)
                )
                let confirmation = try await readAdmissionFrame(
                    from: stream.receiveStream,
                    initialBuffer: admission.trailingBytes
                )
                switch confirmation.frame {
                case .serverReady:
                    break
                case let .denied(code):
                    throw CmxIrohClientSessionError.admissionDenied(code: code)
                case .acceptedPendingNatTraversal, .acceptedRelayOnly, .clientReady:
                    throw CmxIrohClientSessionError.invalidAdmissionFrame
                }
                try Task.checkCancellation()
                return CmxIrohConnectedControl(
                    connection: establishedConnection,
                    stream: stream,
                    initialReceiveBuffer: confirmation.trailingBytes
                )
            case let .denied(code):
                throw CmxIrohClientSessionError.admissionDenied(code: code)
            case .clientReady, .serverReady:
                throw CmxIrohClientSessionError.invalidAdmissionFrame
            }
        } catch {
            await establishedConnection.close(errorCode: 1, reason: "admission_failed")
            throw error
        }
    }

    private func readAdmissionFrame(
        from receiveStream: any CmxIrohReceiveStream,
        initialBuffer: Data = Data()
    ) async throws -> (frame: CmxIrohAdmissionFrame, trailingBytes: Data) {
        var buffer = initialBuffer
        while buffer.count < CmxIrohAdmissionAckCodec.frameByteCount {
            let remaining = CmxIrohAdmissionAckCodec.frameByteCount - buffer.count
            guard let bytes = try await receiveStream.receive(maximumByteCount: remaining),
                  !bytes.isEmpty else {
                throw CmxIrohClientSessionError.unexpectedEndOfStream
            }
            buffer.append(bytes)
        }
        return (
            try admissionCodec.decodeFramePrefix(buffer),
            Data(buffer.dropFirst(CmxIrohAdmissionAckCodec.frameByteCount))
        )
    }

}
