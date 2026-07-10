public import CMUXMobileCore
public import Foundation

/// An admitted multistream client session over one Iroh QUIC connection.
public actor CmxIrohClientSession {
    private let endpoint: any CmxIrohEndpoint
    private let targetIdentity: CmxIrohPeerIdentity
    private let dialPlan: CmxIrohDialPlan
    private let credential: CmxIrohAdmissionCredential
    private let privateFallbackAuthorization: CmxIrohPrivateFallbackAuthorization?
    private let privateFallbackValidator: (any CmxIrohPrivateFallbackValidating)?
    private let protocolConfiguration: CmxIrohProtocolConfiguration
    private let headerCodec: CmxIrohStreamHeaderCodec
    private let admissionCodec = CmxIrohAdmissionAckCodec()
    private var connectionTask: Task<CmxIrohConnectedControl, any Error>?
    private var connection: (any CmxIrohConnection)?
    private var controlStream: CmxIrohBidirectionalStream?
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
        protocolConfiguration: CmxIrohProtocolConfiguration = .cmuxMobileV1
    ) throws {
        self.endpoint = endpoint
        self.targetIdentity = targetIdentity
        self.dialPlan = dialPlan
        self.credential = credential
        self.privateFallbackAuthorization = privateFallbackAuthorization
        self.privateFallbackValidator = privateFallbackValidator
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

    /// Accepts a peer-created unidirectional lane and removes its binary header.
    ///
    /// - Returns: The lane plus its buffered payload stream.
    /// - Throws: A transport, framing, or lifecycle error.
    public func acceptInboundStream() async throws -> CmxIrohInboundStream {
        guard !closed else { throw CmxIrohClientSessionError.alreadyClosed }
        guard let connection else { throw CmxIrohClientSessionError.notConnected }
        let receiveStream = try await connection.acceptReceiveStream()
        do {
            let decoded = try await readHeader(from: receiveStream)
            switch decoded.header.lane {
            case .serverEvents, .artifact:
                break
            case .control, .terminal:
                throw CmxIrohClientSessionError.invalidOutgoingLane
            }
            let buffered = CmxIrohBufferedReceiveStream(
                base: receiveStream,
                buffer: decoded.trailingBytes
            )
            return CmxIrohInboundStream(
                lane: decoded.header.lane,
                receiveStream: buffered
            )
        } catch {
            await receiveStream.stop(errorCode: 1)
            throw error
        }
    }

    /// Closes the control stream and complete QUIC connection.
    public func close() async {
        guard !closed else { return }
        closed = true
        connectionTask?.cancel()
        connectionTask = nil
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
        let establishedConnection: any CmxIrohConnection
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
            guard !dialPlan.privateFallbackPaths.isEmpty else { throw error }
            guard let privateFallbackValidator else {
                throw CmxIrohPrivateFallbackValidationError.unavailable
            }
            guard let privateFallbackAuthorization,
                  privateFallbackAuthorization.pathHints == dialPlan.privateFallbackPaths else {
                throw CmxIrohPrivateFallbackValidationError.authorizationMismatch
            }
            try await privateFallbackValidator.validatePrivateFallback(
                privateFallbackAuthorization
            )
            try Task.checkCancellation()
            establishedConnection = try await endpoint.connect(
                to: CmxIrohEndpointAddress(
                    identity: targetIdentity,
                    pathHints: dialPlan.privateFallbackPaths
                ),
                alpn: protocolConfiguration.alpn
            )
        }

        do {
            try Task.checkCancellation()
            guard await establishedConnection.remoteIdentity() == targetIdentity else {
                throw CmxIrohClientSessionError.remoteIdentityMismatch
            }
            let stream = try await establishedConnection.openBidirectionalStream()
            let header = try CmxIrohStreamHeader(
                lane: .control,
                credential: credential
            )
            try await stream.sendStream.send(headerCodec.encode(header))
            let admission = try await readAdmission(from: stream.receiveStream)
            switch admission.decision {
            case .accepted:
                return CmxIrohConnectedControl(
                    connection: establishedConnection,
                    stream: stream,
                    initialReceiveBuffer: admission.trailingBytes
                )
            case let .denied(code):
                throw CmxIrohClientSessionError.admissionDenied(code: code)
            }
        } catch {
            await establishedConnection.close(errorCode: 1, reason: "admission_failed")
            throw error
        }
    }

    private func readAdmission(
        from receiveStream: any CmxIrohReceiveStream
    ) async throws -> (decision: CmxIrohAdmissionDecision, trailingBytes: Data) {
        var buffer = Data()
        while buffer.count < CmxIrohAdmissionAckCodec.frameByteCount {
            let remaining = CmxIrohAdmissionAckCodec.frameByteCount - buffer.count
            guard let bytes = try await receiveStream.receive(maximumByteCount: remaining),
                  !bytes.isEmpty else {
                throw CmxIrohClientSessionError.unexpectedEndOfStream
            }
            buffer.append(bytes)
        }
        return (
            try admissionCodec.decodePrefix(buffer),
            Data(buffer.dropFirst(CmxIrohAdmissionAckCodec.frameByteCount))
        )
    }

    private func readHeader(
        from receiveStream: any CmxIrohReceiveStream
    ) async throws -> (header: CmxIrohStreamHeader, trailingBytes: Data) {
        var buffer = Data()
        var requestedByteCount = 16
        while true {
            if buffer.count >= requestedByteCount {
                do {
                    let decoded = try headerCodec.decodePrefix(buffer)
                    return (
                        decoded.header,
                        Data(buffer.dropFirst(decoded.consumedByteCount))
                    )
                } catch let error as CmxIrohStreamHeaderCodecError {
                    if case let .incompleteFrame(requiredByteCount) = error {
                        requestedByteCount = requiredByteCount
                    } else {
                        throw error
                    }
                }
            }
            let remaining = requestedByteCount - buffer.count
            guard let bytes = try await receiveStream.receive(maximumByteCount: remaining),
                  !bytes.isEmpty else {
                throw CmxIrohClientSessionError.unexpectedEndOfStream
            }
            buffer.append(bytes)
        }
    }
}
