extension BackgroundWork {
    /// How many ``BlockingLane/system`` items run at once: the width of Chrome's system DNS pool
    /// (`kDefaultMaxSystemTasks`, net/dns/host_resolver_manager.cc). A system call can hang for its own
    /// timeout (`getaddrinfo` up to 30 s); one hung call must not hold every later one.
    public static let systemWidth = 6

    /// How many of the ``systemWidth`` slots only a ``WorkPriority/userBlocking`` item of no ``LaneCap`` class
    /// takes: neither hung lower work nor a hung resolver holds the slot a person's keychain read or Accessibility
    /// call needs (the reserved-slot mechanism of Chrome's `PrioritizedDispatcher::Limits::reserved_slots`,
    /// net/base/prioritized_dispatcher.h).
    public static let systemReserved = 1

    /// How many host resolutions (``resolveHost(_:shutdown:fileID:line:_:)``) run at once inside
    /// ``BlockingLane/system``. cmux's own limit (plans/cmux-next/chrome-parity/p02-threads.md, task 059), not
    /// Chrome's: Chrome gives DNS a pool of its own, while here DNS shares the lane with Security, Launch Services
    /// and Accessibility, so a hung resolver holds at most this many of its slots.
    public static let hostResolutionCap = 4

    /// How long a ``WorkPriority/bestEffort`` or ``WorkPriority/idle`` system item runs before it stops counting
    /// against the lane's best-effort cap, so hung calls never hold every later low item: Chrome's
    /// `kForegroundMayBlockThreshold` (base/task/thread_pool/thread_group.h), after which `ThreadGroup::BlockingStarted`
    /// raises `max_best_effort_tasks_` for a blocked best-effort task.
    public static let mayBlockThreshold: Duration = .seconds(1)

    /// Runs a host name resolution (`blockingGetaddrinfo`) on ``BlockingLane/system`` at `priority`, boosted
    /// to the caller's priority at the call, and returns its result. The ``MayBlockRunner`` entry point is
    /// `runHostResolution`; this one takes a ``WorkPriority``.
    ///
    /// At most ``hostResolutionCap`` resolutions run at once, and never on the ``systemReserved`` slot: a hung
    /// resolver (each `getaddrinfo` can wait up to 30 s) holds those slots only, so keychain, Launch Services
    /// and Accessibility items still start.
    ///
    /// - Throws: what `body` throws; `CancellationError` as ``run(_:mayBlock:shutdown:fileID:line:_:)``.
    public func resolveHost<T: Sendable>(_ priority: WorkPriority, shutdown: ShutdownBehavior = .skipOnShutdown,
                                         fileID: StaticString = #fileID, line: UInt = #line,
                                         _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        noteAwaited(priority, site: CallSite(fileID: fileID, line: line))
        let start = max(priority, WorkPriority(Task.currentPriority))
        return try await enqueue(nextID(), on: .system, at: start, cap: .hostResolution, shutdown: shutdown,
                                 site: CallSite(fileID: fileID, line: line), body)
    }
}
