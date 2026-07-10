public import Foundation

/// An admitted Mac-side multistream session over one TLS-authenticated Iroh connection.
public actor CmxIrohServerSession {
    private let connection: any CmxIrohConnection
    private let authorizer: any CmxIrohAdmissionAuthorizing
    private let headerCodec: CmxIrohStreamHeaderCodec
    private let admissionCodec = CmxIrohAdmissionAckCodec()
    private var controlStream: CmxIrohBidirectionalStream?
    private var controlReceiveBuffer = Data()
    private var admitted = false
    private var closed = false

    public init(
        connection: any CmxIrohConnection,
        authorizer: any CmxIrohAdmissionAuthorizing,
        protocolConfiguration: CmxIrohProtocolConfiguration = .cmuxMobileV1
    ) throws {
        self.connection = connection
        self.authorizer = authorizer
        headerCodec = try CmxIrohStreamHeaderCodec(configuration: protocolConfiguration)
    }

    /// Accepts exactly one credential-bearing control stream before any other lane.
    public func admit() async throws {
        guard !closed else { throw CmxIrohServerSessionError.alreadyClosed }
        guard !admitted, controlStream == nil else {
            throw CmxIrohServerSessionError.alreadyAdmitted
        }
        let stream = try await connection.acceptBidirectionalStream()
        do {
            let decoded = try await readHeader(from: stream.receiveStream)
            guard decoded.header.lane == .control,
                  let credential = decoded.header.credential else {
                throw CmxIrohServerSessionError.invalidFirstLane
            }
            let peerID = await connection.remoteIdentity()
            let decision = await authorizer.authorize(
                credential: credential,
                authenticatedPeerID: peerID
            )
            try await stream.sendStream.send(admissionCodec.encode(decision))
            switch decision {
            case .accepted:
                admitted = true
                controlStream = stream
                controlReceiveBuffer = decoded.trailingBytes
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

    /// Accepts a client-created terminal or artifact bidirectional lane.
    public func acceptBidirectionalLane() async throws -> (
        lane: CmxIrohLane,
        stream: CmxIrohBidirectionalStream
    ) {
        try requireAdmitted()
        let stream = try await connection.acceptBidirectionalStream()
        do {
            let decoded = try await readHeader(from: stream.receiveStream)
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
        } catch {
            await stream.sendStream.reset(errorCode: 1)
            await stream.receiveStream.stop(errorCode: 1)
            throw error
        }
    }

    /// Opens a server-event or artifact unidirectional lane with its header prewritten.
    public func openSendLane(
        _ lane: CmxIrohLane,
        priority: Int32
    ) async throws -> any CmxIrohSendStream {
        try requireAdmitted()
        switch lane {
        case .serverEvents, .artifact:
            break
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
                throw CmxIrohServerSessionError.unexpectedEndOfStream
            }
            buffer.append(bytes)
        }
    }
}
