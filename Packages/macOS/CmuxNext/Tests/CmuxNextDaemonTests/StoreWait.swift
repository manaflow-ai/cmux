import Observation
@testable import CmuxNextDaemon

extension DaemonStore {
    /// Waits until `condition` holds on the store, which the daemon's event
    /// stream drives. The condition is re-evaluated only when a store
    /// property it read changes (Observation), never on a timer; `timeout`
    /// bounds the wait for an event that never comes.
    func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while true {
            let (changed, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let holds = withObservationTracking(condition) {
                signal.yield()
                signal.finish()
            }
            if holds { return }
            let remaining = deadline - .now
            guard remaining > .zero else { throw DaemonError.timedOut(what) }
            let didChange = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    for await _ in changed { return true }
                    return false
                }
                group.addTask {
                    try? await Task.sleep(for: remaining)
                    return false
                }
                let first = await group.next() ?? false
                group.cancelAll()
                return first
            }
            if !didChange {
                if condition() { return }
                throw DaemonError.timedOut(what)
            }
        }
    }
}
