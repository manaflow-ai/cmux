extension BackgroundWork {
    /// Queues `body` on `lane` at `priority` and returns a handle that awaits it and can raise it later:
    /// Chrome's `UpdateableSequencedTaskRunner` (base/task/updateable_sequenced_task_runner.h) for one item.
    ///
    /// Use it for work started low that a person may wait for later (a keyed load, a prefetch the next
    /// click opens): ``WorkHandle/raise(to:)`` or an await of ``WorkHandle/value`` moves it up while it is
    /// queued and overrides its slot thread's QoS while it runs. Nothing boosts it at the call, and until it
    /// is awaited a best-effort fence holds it like a posted item.
    ///
    /// ```swift
    /// let thumbnail = work.runHandle(.bestEffort, mayBlock: .files) { try render(url) }
    /// // The person opens it: the main-actor await raises the item to user-blocking.
    /// let image = try await thumbnail.value
    /// ```
    ///
    /// - Parameters:
    ///   - priority: how much a person waits for it now.
    ///   - lane: the kind of blocking work `body` does.
    ///   - shutdown: what ``shutdown()`` does with it; default ``ShutdownBehavior/skipOnShutdown``.
    ///   - fileID: the caller's `#fileID`, which names a slow block-shutdown item (leave the default).
    ///   - line: the caller's `#line`.
    ///   - body: the blocking work. It runs on a lane thread, never on the cooperative pool.
    /// - Returns: the item's handle; its ``WorkHandle/value`` is what `body` returns or throws, or
    ///   `CancellationError` when the item was cancelled, dropped by shutdown or refused.
    public func runHandle<T: Sendable>(_ priority: WorkPriority, mayBlock lane: BlockingLane,
                                       shutdown: ShutdownBehavior = .skipOnShutdown,
                                       fileID: StaticString = #fileID, line: UInt = #line,
                                       _ body: @escaping @Sendable () throws -> T) -> WorkHandle<T> {
        let id = nextID()
        let scheduler = lanes[lane.rawValue]
        let handle = WorkHandle<T>(id: id, scheduler: scheduler)
        guard let job = makeJob(id: id, lane: lane, shutdown: shutdown,
                                site: CallSite(fileID: fileID, line: line),
                                work: { handle.complete(Result { try body() }) },
                                abandoned: { handle.complete(.failure(CancellationError())) }) else {
            handle.complete(.failure(CancellationError()))
            return handle
        }
        submitted(scheduler.submit(job, at: priority, posted: true, raisable: true, unless: { false }), job, on: lane)
        return handle
    }
}
