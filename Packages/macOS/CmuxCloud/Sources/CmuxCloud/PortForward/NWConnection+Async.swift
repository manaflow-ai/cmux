import Foundation
import Network

private final class NWConnectionCancellationSafeContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var cancelled = false

    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        let cancelImmediately = cancelled
        if !cancelImmediately { self.continuation = continuation }
        lock.unlock()
        if cancelImmediately {
            continuation.resume(throwing: NWConnection.StreamError.cancelled)
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: NWConnection.StreamError.cancelled)
    }

    func resume(returning value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }
}

/// `async` faces over `NWConnection`'s callback API for the port-forward
/// relay. Each call resumes exactly once. `NWConnection` is safe to drive from
/// any thread, so nothing here needs isolation of its own.
extension NWConnection {
    public enum StreamError: Error, LocalizedError {
        case failed(NWError)
        /// The connection parked in `.waiting` (refused, no route). A loopback
        /// or unix-socket peer never comes back from that, so it is a failure.
        case unreachable(NWError)
        case cancelled
        /// The peer closed before the expected bytes arrived.
        case endedEarly

        public var errorDescription: String? {
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
    public func startAndWaitUntilReady(queue: DispatchQueue) async throws {
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
    public func receiveChunk(maximumLength: Int = 65_536) async throws -> (data: Data?, isComplete: Bool) {
        let pending = NWConnectionCancellationSafeContinuation<(Data?, Bool)>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
                receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                    if let error {
                        pending.resume(throwing: StreamError.failed(error))
                        return
                    }
                    pending.resume(returning: (data, isComplete))
                }
            }
        } onCancel: {
            pending.cancel()
            cancel()
        }
    }

    /// Exactly `count` bytes, or ``StreamError/endedEarly`` when the peer
    /// closes first.
    public func receiveExactly(_ count: Int) async throws -> [UInt8] {
        let pending = NWConnectionCancellationSafeContinuation<[UInt8]>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.install(continuation)
                receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let error {
                        pending.resume(throwing: StreamError.failed(error))
                        return
                    }
                    guard let data, data.count == count else {
                        pending.resume(throwing: StreamError.endedEarly)
                        return
                    }
                    pending.resume(returning: [UInt8](data))
                }
            }
        } onCancel: {
            pending.cancel()
            cancel()
        }
    }

    /// Returns once the stack has accepted all of `data`.
    public func sendAll(_ data: Data) async throws {
        let pending = NWConnectionCancellationSafeContinuation<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                pending.install(continuation)
                send(content: data, completion: .contentProcessed { error in
                    if let error {
                        pending.resume(throwing: StreamError.failed(error))
                    } else {
                        pending.resume(returning: ())
                    }
                })
            }
        } onCancel: {
            pending.cancel()
            cancel()
        }
    }

    /// Half-close: nothing more will be sent; the peer may keep sending.
    public func finishSending() async throws {
        let pending = NWConnectionCancellationSafeContinuation<Void>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                pending.install(continuation)
                send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                    if let error {
                        pending.resume(throwing: StreamError.failed(error))
                    } else {
                        pending.resume(returning: ())
                    }
                })
            }
        } onCancel: {
            pending.cancel()
            cancel()
        }
    }
}
