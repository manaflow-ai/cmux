import Foundation
import Network
import os

/// The small socket surface owned by `DirectWriter`. Keeping the writer on a
/// protocol makes its admission and cancellation behavior testable without a
/// real Network.framework connection; `DirectSocket` is the production
/// implementation.
protocol DirectWriterSocket: Sendable {
    func send(record body: Data) async throws
    func cancel()
}

/// Async wrapper around one NWConnection carrying length-prefixed records:
/// `u32 LE length | body` (the a0-rpc byte-stream convention).
final class DirectSocket: Sendable, DirectWriterSocket {
    let connection: NWConnection
    private let queue: DispatchQueue
    private let readyGate = OSAllocatedUnfairLock<CheckedContinuation<Void, any Error>?>(initialState: nil)

    init(connection: NWConnection) {
        self.connection = connection
        queue = DispatchQueue(label: "cmux.direct.socket")
    }

    /// TCP with no Nagle delay; the kernel keepalive detects a dead path
    /// while idle without any timer of ours.
    static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 6
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .responsiveData
        return parameters
    }

    /// Starts the connection and waits until it is ready. `.waiting` (no
    /// route) fails at once instead of waiting for the network.
    func start() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                readyGate.withLock { $0 = continuation }
                connection.stateUpdateHandler = { [weak self] state in
                    self?.handle(state)
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func handle(_ state: NWConnection.State) {
        let result: Result<Void, DirectSocketError>?
        switch state {
        case .ready: result = .success(())
        case let .waiting(error): result = .failure(.noRoute("\(error)"))
        case let .failed(error): result = .failure(.failed("\(error)"))
        case .cancelled: result = .failure(.cancelled)
        default: result = nil
        }
        guard let result, let continuation = readyGate.withLock({ gate -> CheckedContinuation<Void, any Error>? in
            defer { gate = nil }
            return gate
        }) else { return }
        if case .failure = result { connection.cancel() }
        continuation.resume(with: result.mapError { $0 as any Error })
    }

    func cancel() {
        connection.cancel()
    }

    /// Queues one record. Returns once the kernel accepted it, so a caller
    /// that awaits each send is back-pressured by the socket buffer.
    func send(record body: Data) async throws {
        var length = UInt32(body.count).littleEndian
        var data = Data(bytes: &length, count: 4)
        data.append(body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: DirectSocketError.failed("\(error)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Reads one record of at most `maxLength` bytes.
    func receiveRecord(maxLength: Int) async throws -> Data {
        let header = try await receive(exactly: 4)
        let length = Int(header[header.startIndex]) | Int(header[header.startIndex + 1]) << 8
            | Int(header[header.startIndex + 2]) << 16 | Int(header[header.startIndex + 3]) << 24
        guard length <= maxLength else { throw DirectWireError.recordTooLarge(length) }
        guard length > 0 else { return Data() }
        return try await receive(exactly: length)
    }

    private func receive(exactly count: Int) async throws -> Data {
        var buffer = Data()
        while buffer.count < count {
            let chunk = try await receiveChunk(maximum: count - buffer.count)
            buffer.append(chunk)
        }
        return buffer
    }

    private func receiveChunk(maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { content, _, isComplete, error in
                if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if let error {
                    continuation.resume(throwing: DirectSocketError.failed("\(error)"))
                } else if isComplete {
                    continuation.resume(throwing: DirectSocketError.endOfStream)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}
