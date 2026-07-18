public import Foundation

/// An admitted Mac-side multistream session over one TLS-authenticated Iroh connection.
public actor CmxIrohServerSession {
    private struct HeaderReadResult: Sendable {
        let header: CmxIrohStreamHeader
        let trailingBytes: Data
    }

    private let connection: any CmxIrohConnection
    private let authorizer: any CmxIrohAdmissionAuthorizing
    private let protocolConfiguration: CmxIrohProtocolConfiguration
    private let headerCodec: CmxIrohStreamHeaderCodec
    private let admissionCodec = CmxIrohAdmissionAckCodec()
    private let streamHeaderClock: any CmxIrohRelayClock
    private let streamHeaderTimeout: TimeInterval
    private var controlStream: CmxIrohBidirectionalStream?
    private var controlReceiveBuffer = Data()
    private var admittedPeer: CmxIrohAdmittedPeer?
    private var onlineAdmissionLease: CmxIrohOnlineAdmissionLease?
    private var admissionInProgress = false
    private var admitted = false
    private var closed = false

    public init(
        connection: any CmxIrohConnection,
        authorizer: any CmxIrohAdmissionAuthorizing,
        protocolConfiguration: CmxIrohProtocolConfiguration = .cmuxMobileV1,
        streamHeaderClock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        streamHeaderTimeout: TimeInterval = 5
    ) throws {
        precondition(streamHeaderTimeout > 0)
        self.connection = connection
        self.authorizer = authorizer
        self.protocolConfiguration = protocolConfiguration
        self.streamHeaderClock = streamHeaderClock
        self.streamHeaderTimeout = streamHeaderTimeout
        headerCodec = try CmxIrohStreamHeaderCodec(configuration: protocolConfiguration)
    }

    /// Accepts exactly one credential-bearing control stream before any other lane.
    @discardableResult
    public func admit() async throws -> CmxIrohAdmittedPeer {
        guard !closed else { throw CmxIrohServerSessionError.alreadyClosed }
        guard !admitted, !admissionInProgress, controlStream == nil else {
            throw CmxIrohServerSessionError.alreadyAdmitted
        }
        admissionInProgress = true
        defer { admissionInProgress = false }
        // Keep only the bootstrap control stream available until both peers
        // finish the NAT-authorization barrier.
        let stream: CmxIrohBidirectionalStream
        do {
            try await connection.setIncomingStreamLimits(
                maximumBidirectionalStreamCount: 1,
                maximumUnidirectionalStreamCount: 0
            )
            stream = try await connection.acceptBidirectionalStream()
        } catch {
            await connection.close(errorCode: 1, reason: "invalid_control_stream")
            closed = true
            throw error
        }
        do {
            let decoded = try await Self.readHeader(
                from: stream.receiveStream,
                headerCodec: headerCodec
            )
            guard decoded.header.lane == .control,
                  let credential = decoded.header.credential else {
                throw CmxIrohServerSessionError.invalidFirstLane
            }
            let peerID = await connection.remoteIdentity()
            let authorization = await authorizer.authorize(
                credential: credential,
                authenticatedPeerID: peerID
            )
            let checkedAuthorization: CmxIrohAdmissionAuthorization
            switch authorization {
            case let .accepted(peer, onlineLease)
                where peer.endpointID == peerID && peer.platform == .ios:
                checkedAuthorization = .accepted(peer, onlineLease: onlineLease)
            case .accepted:
                checkedAuthorization = .denied(code: 1)
            case .denied:
                checkedAuthorization = authorization
            }
            let initialAdmissionFrame: Data = switch checkedAuthorization {
            case .accepted:
                admissionCodec.encodeFrame(
                    protocolConfiguration.allowsNATTraversalAfterAdmission
                        ? .acceptedPendingNatTraversal
                        : .acceptedRelayOnly
                )
            case .denied:
                admissionCodec.encode(checkedAuthorization.wireDecision)
            }
            try await stream.sendStream.send(initialAdmissionFrame)
            switch checkedAuthorization {
            case let .accepted(peer, onlineLease):
                let clientReady = try await readAdmissionFrame(
                    from: stream.receiveStream,
                    initialBuffer: decoded.trailingBytes
                )
                guard clientReady.frame == .clientReady else {
                    throw CmxIrohServerSessionError.invalidAdmissionFrame
                }
                if protocolConfiguration.allowsNATTraversalAfterAdmission {
                    try Task.checkCancellation()
                    try await connection.authorizeNatTraversal()
                }
                try Task.checkCancellation()
                try await stream.sendStream.send(
                    admissionCodec.encodeFrame(.serverReady)
                )
                try Task.checkCancellation()
                let applicationLaneCount = protocolConfiguration
                    .maximumConcurrentClientApplicationLaneCount
                if applicationLaneCount > 0 {
                    try await connection.setIncomingStreamLimits(
                        maximumBidirectionalStreamCount: 1 + applicationLaneCount,
                        maximumUnidirectionalStreamCount: 0
                    )
                    try Task.checkCancellation()
                }
                admitted = true
                admittedPeer = peer
                onlineAdmissionLease = onlineLease
                controlStream = stream
                controlReceiveBuffer = clientReady.trailingBytes
                return peer
            case let .denied(code):
                await stream.sendStream.reset(errorCode: 1)
                await stream.receiveStream.stop(errorCode: 1)
                await connection.close(errorCode: 1, reason: "admission_denied")
                closed = true
                throw CmxIrohServerSessionError.admissionDenied(code: code)
            }
        } catch {
            if !admitted, !closed {
                await stream.sendStream.reset(errorCode: 1)
                await stream.receiveStream.stop(errorCode: 1)
                await connection.close(errorCode: 1, reason: "invalid_control_stream")
                closed = true
            }
            throw error
        }
    }

    public func receiveControl(
        maximumByteCount: Int = 64 * 1_024
    ) async throws -> Data? {
        guard maximumByteCount > 0 else {
            throw CmxIrohServerSessionError.unexpectedEndOfStream
        }
        let stream = try admittedControlStream()
        if !controlReceiveBuffer.isEmpty {
            let count = min(maximumByteCount, controlReceiveBuffer.count)
            let value = Data(controlReceiveBuffer.prefix(count))
            controlReceiveBuffer.removeFirst(count)
            return value
        }
        return try await stream.receiveStream.receive(maximumByteCount: maximumByteCount)
    }

    public func sendControl(_ data: Data) async throws {
        try await admittedControlStream().sendStream.send(data)
    }

    /// Returns the exact binding retained when this control stream was admitted.
    public func admittedPeerContext() throws -> CmxIrohAdmittedPeer {
        try requireAdmitted()
        guard let admittedPeer else { throw CmxIrohServerSessionError.notAdmitted }
        return admittedPeer
    }

    /// Returns the online revocation lease retained during admission, when applicable.
    public func admittedOnlineLease() throws -> CmxIrohOnlineAdmissionLease? {
        try requireAdmitted()
        return onlineAdmissionLease
    }

    /// Accepts a client-created terminal or artifact bidirectional lane.
    public func acceptBidirectionalLane() async throws -> (
        lane: CmxIrohLane,
        stream: CmxIrohBidirectionalStream
    ) {
        try requireAdmitted()
        guard protocolConfiguration.maximumConcurrentClientApplicationLaneCount > 0 else {
            throw CmxIrohServerSessionError.applicationLanesUnavailable
        }
        let stream = try await connection.acceptBidirectionalStream()
        do {
            let decoded = try await readApplicationHeader(
                from: stream.receiveStream
            )
            switch decoded.header.lane {
            case .terminal, .artifact:
                break
            case .control, .serverEvents:
                throw CmxIrohServerSessionError.invalidPeerLane
            }
            let buffered = CmxIrohBufferedReceiveStream(
                base: stream.receiveStream,
                buffer: decoded.trailingBytes
            )
            return (
                decoded.header.lane,
                CmxIrohBidirectionalStream(
                    receiveStream: buffered,
                    sendStream: stream.sendStream
                )
            )
        } catch is CancellationError {
            await stream.sendStream.reset(errorCode: 1)
            await stream.receiveStream.stop(errorCode: 1)
            throw CancellationError()
        } catch {
            await stream.sendStream.reset(errorCode: 1)
            await stream.receiveStream.stop(errorCode: 1)
            throw CmxIrohServerSessionError.applicationLaneRejected
        }
    }

    /// Opens the centrally owned server-event lane with its header prewritten.
    public func openSendLane(
        _ lane: CmxIrohLane,
        priority: Int32
    ) async throws -> any CmxIrohSendStream {
        try requireAdmitted()
        switch lane {
        case .serverEvents:
            break
        case .artifact:
            throw CmxIrohServerSessionError.applicationLanesUnavailable
        case .control, .terminal:
            throw CmxIrohServerSessionError.invalidServerLane
        }
        let stream = try await connection.openSendStream()
        do {
            try await stream.setPriority(priority)
            try await stream.send(headerCodec.encode(CmxIrohStreamHeader(lane: lane)))
            return stream
        } catch {
            await stream.reset(errorCode: 1)
            throw error
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        if let controlStream {
            await controlStream.sendStream.reset(errorCode: 0)
            await controlStream.receiveStream.stop(errorCode: 0)
        }
        await connection.close(errorCode: 0, reason: "server_closed")
        self.controlStream = nil
        admittedPeer = nil
        onlineAdmissionLease = nil
        controlReceiveBuffer.removeAll(keepingCapacity: false)
    }

    private func admittedControlStream() throws -> CmxIrohBidirectionalStream {
        try requireAdmitted()
        guard let controlStream else { throw CmxIrohServerSessionError.notAdmitted }
        return controlStream
    }

    private func requireAdmitted() throws {
        guard !closed else { throw CmxIrohServerSessionError.alreadyClosed }
        guard admitted else { throw CmxIrohServerSessionError.notAdmitted }
    }

    private func readApplicationHeader(
        from receiveStream: any CmxIrohReceiveStream
    ) async throws -> HeaderReadResult {
        let headerCodec = headerCodec
        let clock = streamHeaderClock
        let deadline = clock.now().addingTimeInterval(streamHeaderTimeout)
        return try await withThrowingTaskGroup(
            of: HeaderReadResult.self
        ) { group in
            group.addTask {
                try await Self.readHeader(
                    from: receiveStream,
                    headerCodec: headerCodec
                )
            }
            group.addTask {
                try await clock.sleep(until: deadline)
                try Task.checkCancellation()
                await receiveStream.stop(errorCode: 1)
                throw CmxIrohServerSessionError.streamHeaderTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            return first
        }
    }

    private static func readHeader(
        from receiveStream: any CmxIrohReceiveStream,
        headerCodec: CmxIrohStreamHeaderCodec
    ) async throws -> HeaderReadResult {
        var buffer = Data()
        var requestedByteCount = 16
        while true {
            if buffer.count >= requestedByteCount {
                do {
                    let decoded = try headerCodec.decodePrefix(buffer)
                    return HeaderReadResult(
                        header: decoded.header,
                        trailingBytes: Data(
                            buffer.dropFirst(decoded.consumedByteCount)
                        )
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
                throw CmxIrohServerSessionError.unexpectedEndOfStream
            }
            buffer.append(bytes)
        }
    }

    private func readAdmissionFrame(
        from receiveStream: any CmxIrohReceiveStream,
        initialBuffer: Data
    ) async throws -> (frame: CmxIrohAdmissionFrame, trailingBytes: Data) {
        var buffer = initialBuffer
        while buffer.count < CmxIrohAdmissionAckCodec.frameByteCount {
            let remaining = CmxIrohAdmissionAckCodec.frameByteCount - buffer.count
            guard let bytes = try await receiveStream.receive(maximumByteCount: remaining),
                  !bytes.isEmpty else {
                throw CmxIrohServerSessionError.unexpectedEndOfStream
            }
            buffer.append(bytes)
        }
        return (
            try admissionCodec.decodeFramePrefix(buffer),
            Data(buffer.dropFirst(CmxIrohAdmissionAckCodec.frameByteCount))
        )
    }
}
