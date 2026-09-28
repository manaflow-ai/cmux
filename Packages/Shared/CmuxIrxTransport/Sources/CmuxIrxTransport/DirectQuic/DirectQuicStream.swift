import Foundation
import Network

/// One Network.framework QUIC stream serving both carrier halves.
final class DirectQuicStream: IrxCarrierSendStream, IrxCarrierRecvStream, @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var receivedEOF = false
    private var sendDone = false
    private var receiveDone = false

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Starts an outbound stream and announces its kind.
    static func open(
        in group: NWConnectionGroup,
        kind: DirectQuicProtocol.StreamKind,
        queue: DispatchQueue
    ) async throws -> DirectQuicStream {
        guard let connection = NWConnection(from: group) else {
            throw DirectQuicError.streamUnavailable
        }
        let stream = DirectQuicStream(connection)
        connection.start(queue: queue)
        try await stream.writeAll(Data([kind.rawValue]))
        return stream
    }

    func writeAll(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, isComplete: false, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    func finish() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        markDone(send: true)
    }

    func reset(errorCode: UInt64) async throws {
        setStreamError(errorCode)
        lock.withLock {
            sendDone = true
            receiveDone = true
        }
        connection.cancel()
    }

    /// Network.framework has no per-stream priority knob; lanes are
    /// independent streams, so ordering between them is already fair.
    func setPriority(_ priority: Int32) async throws {}

    func read(sizeLimit: UInt32) async throws -> Data {
        if lock.withLock({ receivedEOF }) { return Data() }
        let limit = max(1, Int(sizeLimit))
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: limit) { [self] data, _, isComplete, error in
                if let data, !data.isEmpty {
                    if isComplete { markEOF() }
                    continuation.resume(returning: data)
                } else if isComplete {
                    markEOF()
                    continuation.resume(returning: Data())
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    markEOF()
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    /// Reads exactly `count` bytes or throws on early EOF.
    func readExactly(_ count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let chunk = try await read(sizeLimit: UInt32(count - buffer.count))
            guard !chunk.isEmpty else { throw DirectQuicError.handshakeFailed("stream ended early") }
            buffer.append(chunk)
        }
        return buffer
    }

    func stop(errorCode: UInt64) async throws {
        if errorCode != 0 { setStreamError(errorCode) }
        markDone(send: false)
    }

    /// Releases the half of a one-way lane this side never uses.
    func abandon(send: Bool) {
        markDone(send: send)
    }

    private func markEOF() {
        lock.withLock { receivedEOF = true }
    }

    private func markDone(send: Bool) {
        let cancel = lock.withLock { () -> Bool in
            if send { sendDone = true } else { receiveDone = true }
            return sendDone && receiveDone
        }
        if cancel { connection.cancel() }
    }

    private func setStreamError(_ code: UInt64) {
        if let metadata = connection.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata {
            metadata.streamApplicationErrorCode = code
        }
    }
}
