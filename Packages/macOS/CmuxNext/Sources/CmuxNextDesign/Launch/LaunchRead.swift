import CmuxNextCompat
public import CmuxNextWakeups

/// One read of what the last quit saved for this launch, started at once on a `BackgroundWork` lane, whose result
/// the main thread can look at without waiting.
///
/// The app starts it in `main`, before `NSApplication.run`: the main thread then stays inside
/// `applicationDidFinishLaunching` while the first windows and panes are built, so a result that had to hop to
/// the main actor would land only after them. ``value`` is the result as soon as the lane has it, from any
/// thread; nil while the read runs. Async callers (a page's handshake, the quit) await ``finished()`` instead.
///
/// ```swift
/// let pages = LaunchRead(on: work) { readEverySavedPage() }
/// let page = pages.value?[key]   // at the pane's first frame: never waits
/// ```
public nonisolated final class LaunchRead<Value: Sendable>: Sendable {
    // concurrency-allow: the result slot, written once by the lane thread and read synchronously by the main thread
    // at a pane's first frame, where an actor hop would land after the windows are built (lock carve-out: a
    // short critical section over one value and its waiters, no I/O under it).
    private let state = Mutex(State())

    private struct State {
        var value: Value?
        var waiters: [CheckedContinuation<Value, Never>] = []
    }

    /// Starts `body` on `work`'s files lane.
    ///
    /// - Parameters:
    ///   - work: The app's blocking-work lanes.
    ///   - priority: How much a person waits for it; default ``WorkPriority/userBlocking`` (a pane's first frame).
    ///   - shutdown: What quit does with it before it has started; ``ShutdownBehavior/blockShutdown`` when a
    ///     ``finished()`` must end (quit itself awaits it), else dropped and ``value`` stays nil.
    ///   - body: The blocking read. It runs on a lane thread.
    public init(on work: BackgroundWork, priority: WorkPriority = .userBlocking, shutdown: ShutdownBehavior = .skipOnShutdown,
                _ body: @escaping @Sendable () -> Value) {
        work.post(priority, mayBlock: .files, shutdown: shutdown) { [self] in
            let value = body()
            let waiters = self.state.withLock { state in
                state.value = value
                defer { state.waiters = [] }
                return state.waiters
            }
            for waiter in waiters { waiter.resume(returning: value) }
        }
    }

    /// The result once the read has ended; nil while it runs (or when quit dropped it before it started).
    public var value: Value? {
        state.withLock { $0.value }
    }

    /// The result, once the read has ended (the caller suspends; no thread waits).
    public func finished() async -> Value {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value, Never>) in
            let value = state.withLock { state -> Value? in
                if state.value == nil { state.waiters.append(continuation) }
                return state.value
            }
            if let value { continuation.resume(returning: value) }
        }
    }
}
