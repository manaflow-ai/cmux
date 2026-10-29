public import CmuxNextCompat

/// The app's one ``BackgroundWork`` is the ``MayBlockRunner`` that modules below Wakeups take by `init`.
extension BackgroundWork: MayBlockRunner {
    /// Runs `body` on the files lane at `priority` and returns what it returns (``MayBlockRunner``'s file I/O entry).
    ///
    /// - Parameters:
    ///   - priority: How much a person waits for it.
    ///   - shutdown: What quit does with it.
    ///   - site: The caller's file and line, which name a slow or hung item.
    ///   - body: The blocking work.
    public func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                      _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await run(WorkPriority(priority), mayBlock: .files, shutdown: ShutdownBehavior(shutdown),
                      fileID: site.fileID, line: site.line, body)
    }

    /// Runs `body` on the system lane (a blocking system call that is not file I/O) and returns what it returns.
    ///
    /// - Parameters: As ``runFiles(_:shutdown:site:_:)``.
    public func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                       _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await run(WorkPriority(priority), mayBlock: .system, shutdown: ShutdownBehavior(shutdown),
                      fileID: site.fileID, line: site.line, body)
    }

    /// Runs `body`, a host name resolution, on the host resolution lane
    /// and returns what it returns.
    ///
    /// - Parameters: As ``runFiles(_:shutdown:site:_:)``.
    public func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                               _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await resolveHost(WorkPriority(priority), shutdown: ShutdownBehavior(shutdown),
                              fileID: site.fileID, line: site.line, body)
    }

    /// Queues `body` on the files lane and returns at once; nothing waits for it.
    ///
    /// - Parameters: As ``runFiles(_:shutdown:site:_:)``.
    public func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                          _ body: @escaping @Sendable () -> Void) {
        post(WorkPriority(priority), mayBlock: .files, shutdown: ShutdownBehavior(shutdown),
             fileID: site.fileID, line: site.line, body)
    }
}

extension WorkPriority {
    /// The level of a Compat ``MayBlockPriority``: the same name, so the same QoS.
    public init(_ priority: MayBlockPriority) {
        switch priority {
        case .idle: self = .idle
        case .bestEffort: self = .bestEffort
        case .userVisible: self = .userVisible
        case .userBlocking: self = .userBlocking
        }
    }
}

extension ShutdownBehavior {
    /// The behavior of a Compat ``MayBlockShutdown``.
    public init(_ shutdown: MayBlockShutdown) {
        switch shutdown {
        case .continueOnShutdown: self = .continueOnShutdown
        case .skipOnShutdown: self = .skipOnShutdown
        case .blockShutdown: self = .blockShutdown
        }
    }
}
