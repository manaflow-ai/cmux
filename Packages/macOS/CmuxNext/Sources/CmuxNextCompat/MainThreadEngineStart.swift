import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

/// Main-thread time spent in a declared engine start step: Chromium's
/// `CefInitialize` and its first browser window (`CEFRuntime`,
/// `CEFPaneHost`). Chromium requires both on the main thread, and each holds
/// it for a time no control request can shorten (0.1 s on a fast Mac, 0.8 s or
/// more in a macOS 26 VM, mostly waiting on page-ins and the window server).
///
/// Control deadlines do not count this time (`ControlDeadline`,
/// `MainActorWorkQueue`): when a request's deadline comes, the time the main
/// thread spent in a step since the request started moves the deadline out,
/// and while a step still runs the deadline waits for the step's end (the
/// lifecycle signal, never a poll). A request that waited only on its own
/// work still times out at its deadline. ``maxCredit`` bounds what one
/// request gets back, also while a step still runs, so a step that never
/// ends (a hung CefInitialize, a modal run loop inside Chromium's work)
/// holds a request at most that much longer.
public final class MainThreadEngineStart: Sendable {
    public static let shared = MainThreadEngineStart()

    /// The most step time one request gets back.
    public static let maxCredit: Duration = .seconds(30)

    private struct State {
        /// Time of every step that ended.
        var finished: Duration = .zero
        /// Start of the step that runs now (steps do not nest; an inner one
        /// only counts as the outer one).
        var activeSince: ContinuousClock.Instant?
        var depth = 0
        var nextWaiter = 0
        var waiters: [Int: OnceContinuation<Void, OnceContinuationError>] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// Runs `body`, a synchronous main-thread engine start step, and counts
    /// its time as step time.
    public func run<T, E: Error>(_ body: () throws(E) -> T) throws(E) -> T {
        state.withLock { state in
            if state.depth == 0 { state.activeSince = .now }
            state.depth += 1
        }
        defer { end() }
        return try body()
    }

    /// Step time so far, a step that runs now included.
    public var total: Duration {
        state.withLock { state in
            state.finished + (state.activeSince.map { .now - $0 } ?? .zero)
        }
    }

    public var isRunning: Bool { state.withLock { $0.activeSince != nil } }

    /// `deadline` moved out by the step time since `mark`, at most ``maxCredit``.
    public func movedDeadline(_ deadline: ContinuousClock.Instant, countingFrom mark: Duration) -> ContinuousClock.Instant {
        deadline + min(max(total - mark, .zero), Self.maxCredit)
    }

    /// Returns when no step runs (at once when none does), at `limit`, or
    /// when the task is cancelled. The `limit` wake may fire up to
    /// `tolerance` late.
    public func waitUntilIdle(until limit: ContinuousClock.Instant, tolerance: Duration) async {
        let id = state.withLock { state -> Int? in
            guard state.activeSince != nil else { return nil }
            state.nextWaiter += 1
            return state.nextWaiter
        }
        guard let id else { return }
        let bound = Task { [weak self] in
            // wakeup-allow: deadline bound of a wait for a step's end, cancelled when the step ends
            // timer-class-allow: off main: the bound of a wait for a step's end, in this wait's own task
            do { try await Task.sleep(until: limit, tolerance: tolerance, clock: .continuous) } catch { return }
            self?.state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: ())
        }
        defer { bound.cancel() }
        await withTaskCancellationHandler {
            // A dropped waiter returns as the step's end does: the deadline is checked again.
            _ = try? await withOnceContinuation { (continuation: OnceContinuation<Void, OnceContinuationError>) in
                let resumeNow = state.withLock { state -> Bool in
                    // A bound that fired before this waiter was stored found nothing to resume.
                    guard state.activeSince != nil, !Task.isCancelled, ContinuousClock.now < limit else { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume(returning: ()) }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: ())
        }
    }

    /// Sleeps until `deadline` moved out by the step time since `mark` (a
    /// ``total`` read when the request started), at most ``maxCredit``.
    /// Each wake may fire up to `tolerance` late: callers pass the
    /// `WakeLeeway` of their deadline (CmuxNextWakeups, a module above this
    /// one). Throws `CancellationError` when the task is cancelled.
    public func waitPast(_ deadline: ContinuousClock.Instant, countingFrom mark: Duration,
                         tolerance: Duration) async throws {
        var target = deadline
        // wakeup-allow: bounded: a turn repeats only when step time moved the deadline out, by at most maxCredit in all
        while true {
            // wakeup-allow: deadline of the request, cancelled when the request answers
            // timer-class-allow: off main: the request's own deadline, in the request's task
            try await Task.sleep(until: target, tolerance: tolerance, clock: .continuous)
            await waitUntilIdle(until: deadline + Self.maxCredit, tolerance: tolerance)
            try Task.checkCancellation()
            let moved = movedDeadline(deadline, countingFrom: mark)
            guard moved > .now else { return }
            target = moved
        }
    }

    private func end() {
        let waiters = state.withLock { state -> [OnceContinuation<Void, OnceContinuationError>] in
            state.depth -= 1
            guard state.depth == 0, let since = state.activeSince else { return [] }
            state.finished += .now - since
            state.activeSince = nil
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume(returning: ()) }
    }
}
