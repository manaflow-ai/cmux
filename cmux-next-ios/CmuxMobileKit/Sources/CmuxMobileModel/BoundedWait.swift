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
    ///
    /// The wait is also registered with ``MainThreadWaitRegistry/shared`` under `label`: if
    /// the limit's own timer cannot run (a starved executor), the hang watchdog's thread ends
    /// the wait at the same bound.
    public func run(_ label: String = "BoundedWait", _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await run(on: ContinuousClock(), registry: .shared, label: label, work)
    }

    /// ``run(_:)`` with the limit timed on `clock` (tests pass one that moves only when told to).
    @discardableResult
    public func run<C: Clock<Duration>>(on clock: C, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await run(on: clock, registry: nil, label: "", work)
    }

    /// ``run(on:_:)``, with the wait registered in `registry` (nil: none) for the hang watchdog.
    @discardableResult
    public func run<C: Clock<Duration>>(on clock: C, registry: MainThreadWaitRegistry?, label: String,
                                        _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let limit = limit
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let worker = Task {
                await work()
                once.resume(true)
            }
            // The watchdog thread's cancel: thread-safe (ResumeOnce's lock, Task.cancel).
            let registration = registry?.register(label, bound: limit) {
                if once.resume(false) { worker.cancel() }
            }
            Task {
                try? await clock.sleep(for: limit)
                if once.resume(false) { worker.cancel() }
            }
            if let registration {
                Task {
                    _ = await worker.value
                    registration.finish()
                }
            }
        }
    }
}

/// Resumes a continuation at most once, from either side of a race.
private final class ResumeOnce: @unchecked Sendable { // crash-allow: lock-guarded state
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    /// True when this call resumed it.
    @discardableResult
    func resume(_ value: Bool) -> Bool {
        let pending: CheckedContinuation<Bool, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
        return pending != nil
    }
}
