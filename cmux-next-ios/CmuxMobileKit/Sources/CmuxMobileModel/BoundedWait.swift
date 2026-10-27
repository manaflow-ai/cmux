import CmuxSafeConcurrency
import Foundation

/// Waits for work at most `limit`, then returns while the work goes on in
/// the background. Unlike a task group (which awaits every child at scope
/// exit), the bound holds even when the work ignores cancellation, say a
/// receive on a half-dead link (review m4: sign-out's "at most 3 s").
public struct BoundedWait: Sendable {
    public let limit: Duration

    public init(_ limit: Duration) {
        self.limit = limit
    }

    /// Returns true when the work finished within the limit.
    @discardableResult
    public func run(_ work: @escaping @Sendable () async -> Void) async -> Bool {
        let limit = limit
        let worker = Task { await work() }
        // The wait for the work: cancellable, so the limit ends it at once and the work's late end is a no-op.
        let wait = Task {
            try await withOnceThrowingContinuation(cancellation: .cancellable) { (finished: OnceContinuation<Void, any Error>) in
                Task {
                    await worker.value
                    finished.resume(returning: ())
                }
            }
        }
        let deadline = Task {
            try? await Task.sleep(for: limit)
            wait.cancel()
        }
        let finished = (try? await wait.value) != nil
        deadline.cancel()
        if !finished { worker.cancel() }
        return finished
    }
}
