import CmuxNextCompat
import class CmuxSafeConcurrency.OnceContinuation
import enum CmuxSafeConcurrency.OnceContinuationError
import func CmuxSafeConcurrency.withOnceContinuation

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
        var waiters: [OnceContinuation<Value, OnceContinuationError>] = []
        /// ``valueNow(orPostTo:class:owner:file:line:_:)`` steps that wait for the result.
        var landings: [@Sendable (Value) -> Void] = []
    }

    /// Starts `body` on `work`'s `lane` (the files lane unless it says otherwise).
    ///
    /// - Parameters:
    ///   - work: The app's blocking-work lanes.
    ///   - priority: How much a person waits for it; default ``WorkPriority/userBlocking`` (a pane's first frame).
    ///   - lane: The kind of blocking work `body` does; ``BlockingLane/system`` for a Security or other daemon call.
    ///   - shutdown: What quit does with it before it has started; ``ShutdownBehavior/blockShutdown`` when a
    ///     ``finished()`` must end (quit itself awaits it), else dropped and ``value`` stays nil.
    ///   - dropped: The result when quit drops the read before it started or refuses it (posted after
    ///     `work.shutdown()` returned), so ``value`` has it and ``finished()`` ends; nil leaves both waiting.
    ///   - fileID: The caller's `#fileID`, which names a slow block-shutdown read (leave the default).
    ///   - line: The caller's `#line`.
    ///   - body: The blocking read. It runs on a lane thread.
    public init(on work: BackgroundWork, priority: WorkPriority = .userBlocking, mayBlock lane: BlockingLane = .files,
                shutdown: ShutdownBehavior = .skipOnShutdown, dropped: Value? = nil, fileID: StaticString = #fileID, line: UInt = #line,
                _ body: @escaping @Sendable () -> Value) {
        work.post(priority, mayBlock: lane, shutdown: shutdown, fileID: fileID, line: line,
                  abandoned: { [self] in if let dropped { end(with: dropped) } }) { [self] in end(with: body()) }
    }

    /// Starts `body` in `sequence`, after every item posted to it before: a read whose result a later read's
    /// user needs first goes before it in one sequence (the files lane runs other reads of a priority at once).
    /// The result is stored before the next item of `sequence` starts.
    ///
    /// - Parameters:
    ///   - sequence: The sequence of reads it runs in, on its lane.
    ///   - priority: How much a person waits for it; default ``WorkPriority/userBlocking``.
    ///   - shutdown: What quit does with it before it has started (as ``init(on:priority:shutdown:dropped:fileID:line:_:)``).
    ///   - dropped: The result when quit drops the read before it started or refuses it.
    ///   - fileID: The caller's `#fileID` (leave the default).
    ///   - line: The caller's `#line`.
    ///   - body: The blocking read. It runs on a lane thread.
    public init(in sequence: WorkSequence, priority: WorkPriority = .userBlocking, shutdown: ShutdownBehavior = .skipOnShutdown,
                dropped: Value? = nil, fileID: StaticString = #fileID, line: UInt = #line,
                _ body: @escaping @Sendable () -> Value) {
        sequence.post(priority, shutdown: shutdown, fileID: fileID, line: line,
                      abandoned: { [self] in if let dropped { end(with: dropped) } }) { [self] in end(with: body()) }
    }

    /// Stores the result, resumes every ``finished()`` waiting for it and posts every waiting landing step.
    private func end(with value: Value) {
        let (waiters, landings) = state.withLock { state in
            state.value = value
            defer { (state.waiters, state.landings) = ([], []) }
            return (state.waiters, state.landings)
        }
        for waiter in waiters { waiter.resume(returning: value) }
        for landing in landings { landing(value) }
    }

    /// The result now when the read has ended; else nil, and `landed` is posted to `mainWork` in `workClass` as
    /// `owner` with the result when it ends. A launch step that needs the result runs it at once with the value
    /// returned, or follows it this way, and never waits for it (Chrome's `PostTaskAndReplyWithResult`,
    /// base/task/task_runner.h).
    ///
    /// ```swift
    /// if let start = read.valueNow(orPostTo: mainWork, class: .visible, owner: "daemon.start", startDaemon) { startDaemon(start) }
    /// ```
    public func valueNow(orPostTo mainWork: MainWorkScheduler, class workClass: BudgetedWorkClass, owner: String,
                         file: StaticString = #fileID, line: UInt = #line,
                         _ landed: @escaping @MainActor @Sendable (Value) -> Void) -> Value? {
        state.withLock { state -> Value? in
            if state.value == nil {
                state.landings.append { value in
                    mainWork.postFromAnyThread(workClass, owner: owner, file: file, line: line) { landed(value) }
                }
            }
            return state.value
        }
    }

    /// The result once the read has ended; nil while it runs (or when quit dropped it and there is no `dropped`).
    public var value: Value? {
        state.withLock { $0.value }
    }

    /// The result, once the read has ended (the caller suspends; no thread waits). The state keeps each
    /// waiter until ``end(with:)``, so a wait is never dropped; one that were waits again.
    public func finished() async -> Value {
        do {
            return try await withOnceContinuation { (continuation: OnceContinuation<Value, OnceContinuationError>) in
                let value = state.withLock { state -> Value? in
                    if state.value == nil { state.waiters.append(continuation) }
                    return state.value
                }
                if let value { continuation.resume(returning: value) }
            }
        } catch {
            return await finished()
        }
    }
}
