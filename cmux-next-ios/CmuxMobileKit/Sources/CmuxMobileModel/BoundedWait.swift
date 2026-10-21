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
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let worker = Task {
                await work()
                once.resume(true)
            }
            Task {
                try? await Task.sleep(for: limit)
                if once.resume(false) { worker.cancel() }
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
