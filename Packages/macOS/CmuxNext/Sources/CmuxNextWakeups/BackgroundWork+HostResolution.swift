extension BackgroundWork {
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
