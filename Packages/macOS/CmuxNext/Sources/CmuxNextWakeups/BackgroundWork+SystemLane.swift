extension BackgroundWork {
    /// How many ``BlockingLane/system`` items run at once: Chrome's limit for concurrent system DNS
    /// lookups (`kDefaultMaxSystemTasks`, net/dns/host_resolver_manager.cc). A system call can hang for
    /// its own timeout (`getaddrinfo` up to 30 s); one hung call must not hold every later one.
    public static let systemWidth = 6

    /// How many of the ``systemWidth`` slots only a ``WorkPriority/userBlocking`` item takes: lower work that
    /// hangs never holds the slot a person's keychain read or Accessibility call needs (Chrome's
    /// `PrioritizedDispatcher::Limits::reserved_slots`, net/base/prioritized_dispatcher.h).
    public static let systemReserved = 1

    /// How many host resolutions (``runHostResolution(_:shutdown:fileID:line:_:)``) run at once inside
    /// ``BlockingLane/system``: a hung resolver holds at most this many slots, never the keychain's or AX's.
    public static let hostResolutionCap = 4

    /// Runs a host name resolution (`blockingGetaddrinfo`) on ``BlockingLane/system`` at `priority`, boosted
    /// to the caller's priority at the call, and returns its result.
    ///
    /// At most ``hostResolutionCap`` resolutions run at once, inside the lane's ``systemWidth`` slots: a hung
    /// resolver (each `getaddrinfo` can wait up to 30 s) holds those slots only, so keychain, Launch Services
    /// and Accessibility items still start at once. Chrome: `HostResolverManager` runs its system tasks through
    /// a `PrioritizedDispatcher` capped at `kDefaultMaxSystemTasks` (net/dns/host_resolver_manager.cc).
    ///
    /// - Throws: what `body` throws; `CancellationError` as ``run(_:mayBlock:shutdown:fileID:line:_:)``.
    public func runHostResolution<T: Sendable>(_ priority: WorkPriority, shutdown: ShutdownBehavior = .skipOnShutdown,
                                               fileID: StaticString = #fileID, line: UInt = #line,
                                               _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let start = max(priority, WorkPriority(Task.currentPriority))
        return try await enqueue(nextID(), on: .system, at: start, cap: .hostResolution, shutdown: shutdown,
                                 site: CallSite(fileID: fileID, line: line), body)
    }
}
