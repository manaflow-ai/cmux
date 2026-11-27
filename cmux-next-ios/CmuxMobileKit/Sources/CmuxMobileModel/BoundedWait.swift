import Foundation
import Observation

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
        await run(on: ContinuousClock(), work)
    }

    /// ``run(_:)`` with the limit timed on `clock` (tests pass one that moves only when told to).
    @discardableResult
    public func run<C: Clock<Duration>>(on clock: C, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let limit = limit
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce(continuation)
            let worker = Task {
                await work()
                once.resume(true)
            }
            Task {
                try? await clock.sleep(for: limit)
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

extension BoundedWait {
    /// Waits on the main actor while `waiting` reads true, woken by Observation on each change
    /// of what it reads (no polling). Cancelling the task ends the wait at once: a wait that
    /// ``run(_:)`` gave up on (it cancels its worker) does not stay suspended, holding what the
    /// closure holds, until the next change that may never come.
    @MainActor
    public static func observing(while waiting: @MainActor () -> Bool) async {
        while waiting(), !Task.isCancelled {
            let gate = ChangeGate()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (changed: CheckedContinuation<Void, Never>) in
                    gate.arm(changed)
                    guard waiting(), !Task.isCancelled else { return gate.open() }
                    withObservationTracking { _ = waiting() } onChange: { gate.open() }
                }
            } onCancel: {
                gate.open()
            }
        }
    }
}

/// One wait for the next change: resumed once, by the change or by cancellation, whichever
/// comes first (cancellation may come before the continuation is armed).
private final class ChangeGate: @unchecked Sendable { // crash-allow: lock-guarded state
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        let resumeNow: Bool = lock.withLock {
            if opened { return true }
            self.continuation = continuation
            return false
        }
        if resumeNow { continuation.resume() }
    }

    func open() {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            opened = true
            defer { continuation = nil }
            return continuation
        }
        pending?.resume()
    }
}
