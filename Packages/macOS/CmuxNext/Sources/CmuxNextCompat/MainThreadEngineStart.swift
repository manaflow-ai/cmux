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
/// request gets back, so a step that never ends does not hold a request
/// forever.
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
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
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

    /// Returns when no step runs (at once when none does), or when the task
    /// is cancelled.
    public func waitUntilIdle() async {
        let id = state.withLock { state -> Int? in
            guard state.activeSince != nil else { return nil }
            state.nextWaiter += 1
            return state.nextWaiter
        }
        guard let id else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state -> Bool in
                    guard state.activeSince != nil, !Task.isCancelled else { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
        }
    }

    /// Sleeps until `deadline` moved out by the step time since `mark` (a
    /// ``total`` read when the request started), at most ``maxCredit``.
    /// Throws `CancellationError` when the task is cancelled.
    public func waitPast(_ deadline: ContinuousClock.Instant, countingFrom mark: Duration) async throws {
        var target = deadline
        // wakeup-allow: each turn sleeps to a deadline or waits for a step's end; it ends at the moved deadline
        while true {
            // wakeup-allow: one-shot request deadline, cancelled when the request answers
            try await Task.sleep(until: target, clock: .continuous)
            await waitUntilIdle()
            try Task.checkCancellation()
            let moved = deadline + min(max(total - mark, .zero), Self.maxCredit)
            guard moved > .now else { return }
            target = moved
        }
    }

    private func end() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.depth -= 1
            guard state.depth == 0, let since = state.activeSince else { return [] }
            state.finished += .now - since
            state.activeSince = nil
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }
}
