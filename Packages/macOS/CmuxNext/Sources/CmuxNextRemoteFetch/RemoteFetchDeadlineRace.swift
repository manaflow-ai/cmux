import CmuxNextCompat
import Foundation

/// Resumes the caller once, with the fetch's result or the deadline's, and cancels the loser.
nonisolated final class DeadlineRace: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Result<RemoteFetchResponse, RemoteFetchFailure>, Never>?
        var result: Result<RemoteFetchResponse, RemoteFetchFailure>?
        var tasks: [Task<Void, Never>] = []
    }

    // carve-out: a cancel handler and two tasks race to resume one continuation; the lock keeps
    // that exactly-once and synchronous (an actor hop could not run inside onCancel).
    private let state = Mutex(State())

    func arm(_ continuation: CheckedContinuation<Result<RemoteFetchResponse, RemoteFetchFailure>, Never>) {
        let early = state.withLock { state -> Result<RemoteFetchResponse, RemoteFetchFailure>? in
            if let result = state.result { return result }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func own(_ tasks: Task<Void, Never>...) {
        let done = state.withLock { state -> Bool in
            state.tasks += tasks
            return state.result != nil
        }
        if done { tasks.forEach { $0.cancel() } }
    }

    func finish(_ result: Result<RemoteFetchResponse, RemoteFetchFailure>) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<Result<RemoteFetchResponse, RemoteFetchFailure>, Never>?, [Task<Void, Never>]) in
            guard state.result == nil else { return (nil, []) }
            state.result = result
            defer { state.continuation = nil }
            return (state.continuation, state.tasks)
        }
        tasks.forEach { $0.cancel() }
        continuation?.resume(returning: result)
    }
}
