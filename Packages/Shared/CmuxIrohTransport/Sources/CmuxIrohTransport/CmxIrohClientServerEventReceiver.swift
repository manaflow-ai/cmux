public import CMUXMobileCore
public import Foundation

/// Fail-closed lifecycle and framing errors for the client-owned server-event
/// accept loop.
public enum CmxIrohClientServerEventReceiverError: Error, Equatable, Sendable {
    case consumerAlreadyActive
    case alreadyClosed
    case headerTimedOut
    case unexpectedEndOfStream
    case backpressureExceeded
}

/// Owns the sole unidirectional-stream accept loop for one admitted client
/// connection and exposes only payload bytes from `serverEvents` lanes.
///
/// Unknown or malformed lanes are stopped without affecting the control
/// stream. One bounded stream is exposed to the RPC frame decoder, preventing
/// feature code from creating competing QUIC accept loops.
public actor CmxIrohClientServerEventReceiver {
    private struct ActiveConsumer: Sendable {
        let id: UUID
        let continuation: CmxIndependentEventByteStream.Continuation
        var task: Task<Void, Never>?
        var currentStream: (any CmxIrohReceiveStream)?
    }

    private struct DecodedHeader: Sendable {
        let header: CmxIrohStreamHeader
        let trailingBytes: Data
    }

    private let connection: any CmxIrohConnection
    private let headerCodec: CmxIrohStreamHeaderCodec
    private let clock: any CmxIrohRelayClock
    private let headerTimeout: TimeInterval
    private let maximumReadByteCount: Int
    private var activeConsumer: ActiveConsumer?
    private var closed = false
    private var incomingStreamCreditEnabled = false

    public init(
        connection: any CmxIrohConnection,
        protocolConfiguration: CmxIrohProtocolConfiguration = .cmuxMobileV1,
        clock: any CmxIrohRelayClock = CmxIrohSystemRelayClock(),
        headerTimeout: TimeInterval = 5,
        maximumReadByteCount: Int = 64 * 1_024
    ) throws {
        self.connection = connection
        self.headerCodec = try CmxIrohStreamHeaderCodec(
            configuration: protocolConfiguration
        )
        self.clock = clock
        self.headerTimeout = headerTimeout
        self.maximumReadByteCount = maximumReadByteCount
    }

    /// Starts the exact one accept owner and grants credit for one concurrent
    /// peer-created unidirectional stream.
    public func byteStream() async throws -> CmxIndependentEventByteStream {
        guard !closed else {
            throw CmxIrohClientServerEventReceiverError.alreadyClosed
        }
        guard activeConsumer == nil else {
            throw CmxIrohClientServerEventReceiverError.consumerAlreadyActive
        }

        try await connection.setIncomingStreamLimits(
            maximumBidirectionalStreamCount: 0,
            maximumUnidirectionalStreamCount: 1
        )
        incomingStreamCreditEnabled = true

        let consumerID = UUID()
        let pair = CmxIndependentEventByteStream.makeStream(
            bufferingPolicy: .bufferingNewest(32)
        )
        pair.continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.cancelConsumer(id: consumerID) }
        }
        activeConsumer = ActiveConsumer(
            id: consumerID,
            continuation: pair.continuation,
            task: nil,
            currentStream: nil
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runAcceptLoop(consumerID: consumerID)
        }
        if activeConsumer?.id == consumerID {
            activeConsumer?.task = task
        } else {
            task.cancel()
        }
        return pair.stream
    }

    /// Revokes peer stream credit and cancels accept, header, and payload reads.
    public func close() async {
        guard !closed else { return }
        closed = true
        await finishConsumer(
            id: activeConsumer?.id,
            error: CancellationError()
        )
        await revokeIncomingStreamCredit()
    }

    private func runAcceptLoop(consumerID: UUID) async {
        do {
            while !Task.isCancelled {
                let receiveStream = try await connection.acceptReceiveStream()
                guard setCurrentStream(receiveStream, for: consumerID) else {
                    await receiveStream.stop(errorCode: 1)
                    throw CancellationError()
                }

                let decoded: DecodedHeader
                do {
                    decoded = try await readHeaderWithDeadline(from: receiveStream)
                } catch {
                    await receiveStream.stop(errorCode: 1)
                    clearCurrentStream(receiveStream, for: consumerID)
                    try Task.checkCancellation()
                    continue
                }

                guard case .serverEvents = decoded.header.lane else {
                    await receiveStream.stop(errorCode: 1)
                    clearCurrentStream(receiveStream, for: consumerID)
                    continue
                }

                if !decoded.trailingBytes.isEmpty {
                    try yield(decoded.trailingBytes, consumerID: consumerID)
                }
                while !Task.isCancelled {
                    guard let bytes = try await receiveStream.receive(
                        maximumByteCount: maximumReadByteCount
                    ) else {
                        break
                    }
                    guard !bytes.isEmpty else { continue }
                    try yield(bytes, consumerID: consumerID)
                }
                clearCurrentStream(receiveStream, for: consumerID)
            }
            throw CancellationError()
        } catch {
            await finishConsumer(id: consumerID, error: error)
        }
    }

    private func readHeaderWithDeadline(
        from receiveStream: any CmxIrohReceiveStream
    ) async throws -> DecodedHeader {
        let codec = headerCodec
        let deadline = clock.now().addingTimeInterval(headerTimeout)
        let clock = clock
        return try await withThrowingTaskGroup(of: DecodedHeader.self) { group in
            group.addTask {
                try await Self.readHeader(from: receiveStream, codec: codec)
            }
            group.addTask {
                try await clock.sleep(until: deadline)
                await receiveStream.stop(errorCode: 1)
                throw CmxIrohClientServerEventReceiverError.headerTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw CmxIrohClientServerEventReceiverError.unexpectedEndOfStream
            }
            return result
        }
    }

    private static func readHeader(
        from receiveStream: any CmxIrohReceiveStream,
        codec: CmxIrohStreamHeaderCodec
    ) async throws -> DecodedHeader {
        var buffer = Data()
        var requestedByteCount = 16
        while true {
            if buffer.count >= requestedByteCount {
                do {
                    let decoded = try codec.decodePrefix(buffer)
                    return DecodedHeader(
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
            guard let bytes = try await receiveStream.receive(
                maximumByteCount: remaining
            ), !bytes.isEmpty else {
                throw CmxIrohClientServerEventReceiverError.unexpectedEndOfStream
            }
            buffer.append(bytes)
        }
    }

    private func yield(_ bytes: Data, consumerID: UUID) throws {
        guard let activeConsumer, activeConsumer.id == consumerID else {
            throw CancellationError()
        }
        switch activeConsumer.continuation.yield(bytes) {
        case .enqueued:
            return
        case .dropped:
            throw CmxIrohClientServerEventReceiverError.backpressureExceeded
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw CmxIrohClientServerEventReceiverError.backpressureExceeded
        }
    }

    private func setCurrentStream(
        _ stream: any CmxIrohReceiveStream,
        for consumerID: UUID
    ) -> Bool {
        guard activeConsumer?.id == consumerID else { return false }
        activeConsumer?.currentStream = stream
        return true
    }

    private func clearCurrentStream(
        _ stream: any CmxIrohReceiveStream,
        for consumerID: UUID
    ) {
        guard activeConsumer?.id == consumerID else { return }
        activeConsumer?.currentStream = nil
    }

    private func cancelConsumer(id consumerID: UUID) async {
        guard activeConsumer?.id == consumerID else { return }
        await finishConsumer(id: consumerID, error: CancellationError())
    }

    private func finishConsumer(id consumerID: UUID?, error: (any Error)?) async {
        guard let consumerID,
              let activeConsumer,
              activeConsumer.id == consumerID else {
            return
        }
        self.activeConsumer = nil
        activeConsumer.task?.cancel()
        if let currentStream = activeConsumer.currentStream {
            await currentStream.stop(errorCode: 1)
        }
        if let error {
            activeConsumer.continuation.finish(throwing: error)
        } else {
            activeConsumer.continuation.finish()
        }
        await revokeIncomingStreamCredit()
    }

    private func revokeIncomingStreamCredit() async {
        guard incomingStreamCreditEnabled else { return }
        incomingStreamCreditEnabled = false
        try? await connection.setIncomingStreamLimits(
            maximumBidirectionalStreamCount: 0,
            maximumUnidirectionalStreamCount: 0
        )
    }
}
