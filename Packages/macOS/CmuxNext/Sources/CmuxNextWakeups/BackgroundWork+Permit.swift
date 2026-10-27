public import CmuxNextCompat

/// The permit forms of every lane entry point: the body gets the lane's ``BlockingPermit``, the only way to call a
/// seam overload that takes one (Chrome's `MayBlock()` trait as a type, plans/cmux-next/chrome-parity/p02-threads.md
/// task 111). On ``BlockingLane/cpu`` the permit compiles too; the run-time detector records a seam there as
/// ``BlockingKind/wrongLane``.
///
/// ```swift
/// let bytes = try await work.run(.userVisible, mayBlock: .files) { permit in try Data(blockingContentsOf: url, permit) }
/// saves.post(.bestEffort, shutdown: .blockShutdown) { permit in try? bytes.blockingWrite(to: url, permit, options: .atomic) }
/// ```
extension BackgroundWork {
    /// ``run(_:mayBlock:shutdown:fileID:line:_:)`` whose body gets the lane's ``BlockingPermit``.
    public func run<T: Sendable>(_ priority: WorkPriority, mayBlock lane: BlockingLane,
                                 shutdown: ShutdownBehavior = .skipOnShutdown,
                                 fileID: StaticString = #fileID, line: UInt = #line,
                                 _ body: @escaping @Sendable (borrowing BlockingPermit) throws -> T) async throws -> T {
        try await run(priority, mayBlock: lane, shutdown: shutdown, fileID: fileID, line: line) { () throws -> T in
            try body(BlockingPermit(issuer: .lane))
        }
    }

    /// ``post(_:mayBlock:shutdown:fileID:line:abandoned:_:)`` whose body gets the lane's ``BlockingPermit``.
    public func post(_ priority: WorkPriority, mayBlock lane: BlockingLane,
                     shutdown: ShutdownBehavior = .skipOnShutdown,
                     fileID: StaticString = #fileID, line: UInt = #line,
                     abandoned: @escaping @Sendable () -> Void = {},
                     _ body: @escaping @Sendable (borrowing BlockingPermit) -> Void) {
        post(priority, mayBlock: lane, shutdown: shutdown, fileID: fileID, line: line, abandoned: abandoned) { () -> Void in
            body(BlockingPermit(issuer: .lane))
        }
    }

    /// ``runHandle(_:mayBlock:shutdown:fileID:line:_:)`` whose body gets the lane's ``BlockingPermit``.
    public func runHandle<T: Sendable>(_ priority: WorkPriority, mayBlock lane: BlockingLane,
                                       shutdown: ShutdownBehavior = .skipOnShutdown,
                                       fileID: StaticString = #fileID, line: UInt = #line,
                                       _ body: @escaping @Sendable (borrowing BlockingPermit) throws -> T) -> WorkHandle<T> {
        runHandle(priority, mayBlock: lane, shutdown: shutdown, fileID: fileID, line: line) { () throws -> T in
            try body(BlockingPermit(issuer: .lane))
        }
    }

    /// ``resolveHost(_:shutdown:fileID:line:_:)`` whose body gets the lane's ``BlockingPermit`` (for
    /// `blockingGetaddrinfo`).
    public func resolveHost<T: Sendable>(_ priority: WorkPriority, shutdown: ShutdownBehavior = .skipOnShutdown,
                                         fileID: StaticString = #fileID, line: UInt = #line,
                                         _ body: @escaping @Sendable (borrowing BlockingPermit) throws -> T) async throws -> T {
        try await resolveHost(priority, shutdown: shutdown, fileID: fileID, line: line) { () throws -> T in
            try body(BlockingPermit(issuer: .lane))
        }
    }

    /// The reply form of ``run(_:mayBlock:shutdown:_:)`` whose body gets the lane's ``BlockingPermit``.
    /// Disfavored for the same reason as the permit-less one: the async permit `run` wins wherever both fit.
    @_disfavoredOverload
    public func run<T: Sendable>(_ priority: WorkPriority, mayBlock lane: BlockingLane, shutdown: ShutdownBehavior = .skipOnShutdown,
                                 _ body: @escaping @Sendable (borrowing BlockingPermit) -> T) -> Pending<T> {
        Pending(work: self, priority: priority, lane: lane, shutdown: shutdown, body: { body(BlockingPermit(issuer: .lane)) })
    }
}

extension WorkSequence {
    /// ``run(_:shutdown:fileID:line:_:)`` whose body gets the lane's ``BlockingPermit``.
    public func run<T: Sendable>(_ priority: WorkPriority, shutdown: ShutdownBehavior = .skipOnShutdown,
                                 fileID: StaticString = #fileID, line: UInt = #line,
                                 _ body: @escaping @Sendable (borrowing BlockingPermit) throws -> T) async throws -> T {
        try await run(priority, shutdown: shutdown, fileID: fileID, line: line) { () throws -> T in
            try body(BlockingPermit(issuer: .lane))
        }
    }

    /// ``post(_:shutdown:fileID:line:abandoned:_:)`` whose body gets the lane's ``BlockingPermit``.
    public func post(_ priority: WorkPriority, shutdown: ShutdownBehavior = .skipOnShutdown,
                     fileID: StaticString = #fileID, line: UInt = #line,
                     abandoned: @escaping @Sendable () -> Void = {},
                     _ body: @escaping @Sendable (borrowing BlockingPermit) -> Void) {
        post(priority, shutdown: shutdown, fileID: fileID, line: line, abandoned: abandoned) { () -> Void in
            body(BlockingPermit(issuer: .lane))
        }
    }
}
