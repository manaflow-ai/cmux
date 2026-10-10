import Foundation
import Network

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

    /// The callback payload kept Sendable while crossing the async bridge.
    private struct ReceivedChunk: Sendable {
        let data: Data?
        let isComplete: Bool

        var tuple: (data: Data?, isComplete: Bool) {
            (data: data, isComplete: isComplete)
        }
    }

    /// Network.framework reports an explicit `cancel()` as a POSIX
    /// `ECANCELED` error on pending callbacks. Keep that distinct from a real
    /// transport failure so deadline cancellation remains cancellation-aware.
    private static func streamError(for error: NWError) -> StreamError {
        if case .posix(.ECANCELED) = error {
            return .cancelled
        }
        return .failed(error)
    }

    private static func unwrap<Value>(_ result: Result<Value, StreamError>) throws -> Value {
        switch result {
        case .success(let value):
            return value
        case .failure(.cancelled):
            throw CancellationError()
        case .failure(let error):
            throw error
        }
    }

    /// Starts the connection on `queue` and returns once it is ready.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    public func startAndWaitUntilReady(queue: DispatchQueue) async throws {
        let outcome = CloudLinkFirstValue<Result<Void, StreamError>>()
        return try await withTaskCancellationHandler {
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
            try Self.unwrap(result)
        } onCancel: {
            cancel()
        }
    }

    /// The next chunk of incoming bytes; `isComplete` marks the peer's end of
    /// stream (the chunk may then be empty).
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    public func receiveChunk(maximumLength: Int = 65_536) async throws -> (data: Data?, isComplete: Bool) {
        let outcome = CloudLinkFirstValue<Result<ReceivedChunk, StreamError>>()
        return try await withTaskCancellationHandler {
            receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, error in
                if let error {
                    outcome.resolve(.failure(Self.streamError(for: error)))
                } else {
                    outcome.resolve(.success(ReceivedChunk(data: data, isComplete: isComplete)))
                }
            }
            let result = await outcome.result ?? .failure(.cancelled)
            return try Self.unwrap(result).tuple
        } onCancel: {
            cancel()
        }
    }

    /// Exactly `count` bytes, or ``StreamError/endedEarly`` when the peer
    /// closes first.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    public func receiveExactly(_ count: Int) async throws -> [UInt8] {
        let outcome = CloudLinkFirstValue<Result<[UInt8], StreamError>>()
        return try await withTaskCancellationHandler {
            receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error {
                    outcome.resolve(.failure(Self.streamError(for: error)))
                    return
                }
                guard let data, data.count == count else {
                    outcome.resolve(.failure(.endedEarly))
                    return
                }
                outcome.resolve(.success([UInt8](data)))
            }
            let result = await outcome.result ?? .failure(.cancelled)
            return try Self.unwrap(result)
        } onCancel: {
            cancel()
        }
    }

    /// Returns once the stack has accepted all of `data`.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    public func sendAll(_ data: Data) async throws {
        let outcome = CloudLinkFirstValue<Result<Void, StreamError>>()
        try await withTaskCancellationHandler {
            send(content: data, completion: .contentProcessed { error in
                if let error {
                    outcome.resolve(.failure(Self.streamError(for: error)))
                } else {
                    outcome.resolve(.success(()))
                }
            })
            let result = await outcome.result ?? .failure(.cancelled)
            try Self.unwrap(result)
        } onCancel: {
            cancel()
        }
    }

    /// Half-close: nothing more will be sent; the peer may keep sending.
    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    public func finishSending() async throws {
        let outcome = CloudLinkFirstValue<Result<Void, StreamError>>()
        try await withTaskCancellationHandler {
            send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error {
                    outcome.resolve(.failure(Self.streamError(for: error)))
                } else {
                    outcome.resolve(.success(()))
                }
            })
            let result = await outcome.result ?? .failure(.cancelled)
            try Self.unwrap(result)
        } onCancel: {
            cancel()
        }
    }
}
