import Foundation
import Network

/// `async` faces over `NWConnection`'s callback API for the port-forward
/// relay. Each call resumes exactly once. `NWConnection` is safe to drive from
/// any thread, so nothing here needs isolation of its own.
extension NWConnection {
    enum StreamError: Error, LocalizedError {
        case failed(NWError)
        /// The connection parked in `.waiting` (refused, no route). A loopback
        /// or unix-socket peer never comes back from that, so it is a failure.
        case unreachable(NWError)
        case cancelled
        /// The peer closed before the expected bytes arrived.
        case endedEarly

        var errorDescription: String? {
            switch self {
            case .failed(let error), .unreachable(let error):
                return error.localizedDescription
            case .cancelled:
                return "The connection was cancelled."
            case .endedEarly:
                return "The connection closed before the handshake finished."
            }
        }
    }

    /// Starts the connection on `queue` and returns once it is ready.
    func startAndWaitUntilReady(queue: DispatchQueue) async throws {
        let outcome = CloudLinkFirstValue<Result<Void, StreamError>>()
        stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.resolve(.success(()))
            case .failed(let error):
                outcome.resolve(.failure(.failed(error)))
            case .waiting(let error):
                outcome.resolve(.failure(.unreachable(error)))
            case .cancelled:
                outcome.resolve(.failure(.cancelled))
            case .setup, .preparing:
                break
            @unknown default:
                break
            }
        }
        start(queue: queue)
        let result = await outcome.result ?? .failure(.cancelled)
        stateUpdateHandler = nil
        try result.get()
    }

    /// The next chunk of incoming bytes; `isComplete` marks the peer's end of
    /// stream (the chunk may then be empty).
    func receiveChunk(maximumLength: Int = 65_536) async throws -> (data: Data?, isComplete: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: StreamError.failed(error))
                    return
                }
                continuation.resume(returning: (data, isComplete))
            }
        }
    }

    /// Exactly `count` bytes, or ``StreamError/endedEarly`` when the peer
    /// closes first.
    func receiveExactly(_ count: Int) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: StreamError.failed(error))
                    return
                }
                guard let data, data.count == count else {
                    continuation.resume(throwing: StreamError.endedEarly)
                    return
                }
                continuation.resume(returning: [UInt8](data))
            }
        }
    }

    /// Returns once the stack has accepted all of `data`.
    func sendAll(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: StreamError.failed(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Half-close: nothing more will be sent; the peer may keep sending.
    func finishSending() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: StreamError.failed(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
