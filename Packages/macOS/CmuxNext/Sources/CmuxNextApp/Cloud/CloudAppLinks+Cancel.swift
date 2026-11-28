import Foundation
import Synchronization

extension CloudAppLinks {
    /// Runs `operation` and stops waiting for it when the caller is
    /// cancelled: the caller gets `CancellationError` at once, the operation
    /// runs to its own end (a daemon request has its deadline) and its late
    /// answer is dropped. For waits that do not see a cancel themselves.
    nonisolated static func abandoningOnCancel<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let slot = ResultSlot<T>()
        // task-owner: the operation ends by itself (its own deadline); a cancelled caller only stops waiting
        let work = Task {
            do { slot.resolve(.success(try await operation())) } catch { slot.resolve(.failure(error)) }
        }
        return try await withTaskCancellationHandler {
            try await slot.value()
        } onCancel: {
            slot.resolve(.failure(CancellationError()))
            work.cancel()
        }
    }
}

/// One result, first resolution wins; a waiter before or after it gets it.
private nonisolated final class ResultSlot<T: Sendable>: Sendable {
    private enum State {
        case waiting(CheckedContinuation<T, any Error>?)
        case done(Result<T, any Error>)
    }

    private let state = Mutex(State.waiting(nil))

    func resolve(_ result: Result<T, any Error>) {
        let waiter: CheckedContinuation<T, any Error>?? = state.withLock { state in
            guard case .waiting(let waiter) = state else { return nil }
            state = .done(result)
            return .some(waiter)
        }
        if case .some(let waiter?) = waiter { waiter.resume(with: result) }
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let done: Result<T, any Error>? = state.withLock { state in
                switch state {
                case .done(let result): return result
                case .waiting: state = .waiting(continuation); return nil
                }
            }
            if let done { continuation.resume(with: done) }
        }
    }
}
