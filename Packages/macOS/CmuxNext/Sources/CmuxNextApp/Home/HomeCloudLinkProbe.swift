import Foundation
import Synchronization

#if DEBUG
/// What a `HomeCloudLink` started and tests wait for: the main-actor hops
/// of source callbacks still in flight, and the timer deadlines the link
/// handled. Tests wait on these signals instead of yielding to the main
/// actor, which a busy test run can hold for minutes.
nonisolated final class HomeCloudLinkProbe: Sendable {
    private struct Waiter {
        var ready: @Sendable (_ hops: Int, _ fires: Int) -> Bool
        var continuation: CheckedContinuation<Void, Never>
    }

    private struct State {
        var hops = 0
        var fires = 0
        var nextID = 0
        var waiters: [Int: Waiter] = [:]
    }

    private let state = Mutex(State())

    /// Hops started and not yet run.
    var hops: Int { state.withLock { $0.hops } }
    /// Timer deadlines the link handled.
    var fires: Int { state.withLock { $0.fires } }

    func hopStarted() { change { $0.hops += 1 } }
    func hopEnded() { change { $0.hops -= 1 } }
    func fired() { change { $0.fires += 1 } }

    /// Returns once `ready` holds, or when the task is cancelled (the
    /// suite's time limit), so a condition that never holds fails the test
    /// instead of hanging the run.
    func wait(until ready: @escaping @Sendable (_ hops: Int, _ fires: Int) -> Bool) async {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let done = state.withLock { state -> Bool in
                    if ready(state.hops, state.fires) || Task.isCancelled { return true }
                    state.waiters[id] = Waiter(ready: ready, continuation: continuation)
                    return false
                }
                if done { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.continuation.resume()
        }
    }

    private func change(_ body: (inout State) -> Void) {
        let woken = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            body(&state)
            let ready = state.waiters.filter { $0.value.ready(state.hops, state.fires) }
            for id in ready.keys { state.waiters[id] = nil }
            return ready.values.map(\.continuation)
        }
        woken.forEach { $0.resume() }
    }
}
#else
/// Release builds keep no test signals.
nonisolated struct HomeCloudLinkProbe: Sendable {
    func hopStarted() {}
    func hopEnded() {}
    func fired() {}
}
#endif
