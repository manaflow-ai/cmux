import Foundation

/// Bridges `withTaskCancellationHandler`'s `onCancel` callback to the timeout
/// stream so the awaiting task's cancellation deterministically finishes the
/// stream instead of racing the value and timeout tasks.
///
/// Safety: `onCancel` is synchronous and can run on any thread concurrently
/// with `install`, so it cannot await an actor; mutual exclusion uses an
/// `NSLock` instead. `@unchecked Sendable` holds because both mutable
/// properties are only touched inside `lock.withLock`, and the continuation
/// is finished at most once because every finish path must first win `race`.
final class RPCTaskTimeoutCancellation<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<T, any Error>.Continuation?
    private var isCancelled = false

    func install(
        _ continuation: AsyncThrowingStream<T, any Error>.Continuation,
        race: RPCTaskTimeoutRace
    ) {
        let shouldCancel = lock.withLock {
            self.continuation = continuation
            return isCancelled
        }
        if shouldCancel {
            finishCancellation(continuation, race: race)
        }
    }

    func cancel(race: RPCTaskTimeoutRace) {
        let continuation = lock.withLock {
            isCancelled = true
            return self.continuation
        }
        guard let continuation else { return }
        finishCancellation(continuation, race: race)
    }

    private func finishCancellation(
        _ continuation: AsyncThrowingStream<T, any Error>.Continuation,
        race: RPCTaskTimeoutRace
    ) {
        Task {
            guard await race.win() else { return }
            continuation.finish(throwing: CancellationError())
        }
    }
}
