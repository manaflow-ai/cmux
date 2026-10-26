import CmuxSafeConcurrency
import Foundation

/// Bridges `withTaskCancellationHandler`'s `onCancel` callback to the timeout
/// stream so the awaiting task's cancellation deterministically finishes the
/// stream instead of racing the value and timeout tasks.
///
/// `onCancel` is synchronous and can run on any thread concurrently with
/// `install`, so it cannot await an actor. The continuation and the
/// cancellation flag live in one `Mutex`, so the type is plainly `Sendable`;
/// the continuation is finished at most once because every finish path must
/// first win `race`.
final class RPCTaskTimeoutCancellation<T: Sendable>: Sendable {
    private struct State {
        var continuation: AsyncThrowingStream<T, any Error>.Continuation?
        var isCancelled = false
    }

    // carve-out: `onCancel` is synchronous and cannot await an actor.
    private let state = Mutex(State())

    func install(
        _ continuation: AsyncThrowingStream<T, any Error>.Continuation,
        race: RPCTaskTimeoutRace
    ) {
        let shouldCancel = state.withLock { state in
            state.continuation = continuation
            return state.isCancelled
        }
        if shouldCancel {
            finishCancellation(continuation, race: race)
        }
    }

    func cancel(race: RPCTaskTimeoutRace) {
        let continuation = state.withLock { state in
            state.isCancelled = true
            return state.continuation
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
