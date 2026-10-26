/// How much a person waits for one piece of blocking work: Chrome's `base::TaskPriority` (base/task/task_traits.h),
/// for a shared package. The four levels of the app's own (CmuxNextCompat's `MayBlockPriority`), one to one.
public enum MayBlockPriority: Int, Sendable, Comparable, CaseIterable {
    /// Nobody waits for it (indexing, cache cleanup).
    case idle
    /// A person does not wait for it now (saves, automation).
    case bestEffort
    /// Its result shows on screen soon (an image a page shows).
    case userVisible
    /// A person waits for it right now (the result of a tap, a key or an open).
    case userBlocking

    public static func < (lhs: MayBlockPriority, rhs: MayBlockPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What quit does with an item: Chrome's `TaskShutdownBehavior` (base/task/task_traits.h).
public enum MayBlockShutdown: Sendable {
    /// Keep running if it has started; drop it if it has not. Quit does not wait for it.
    case continueOnShutdown
    /// Drop it if it has not started (a `run` caller gets `CancellationError`); quit does not wait.
    case skipOnShutdown
    /// Quit waits for it: one short save whose loss loses a person's data.
    case blockShutdown
}

/// Where a ``MayBlockRunner`` item was posted: the caller's `#fileID` and `#line`.
public struct MayBlockCallSite: Sendable {
    /// The caller's `#fileID` (`<module>/<file>.swift`).
    public let fileID: StaticString
    /// The caller's `#line`.
    public let line: UInt

    /// The site of the caller, or of `fileID` and `line` when a wrapper passes its own caller's on.
    public init(fileID: StaticString = #fileID, line: UInt = #line) {
        self.fileID = fileID
        self.line = line
    }
}

/// Runs a shared package's work that may block off the main thread and off Swift's cooperative pool: Chrome's
/// `base::ThreadPool::PostTask` with the `MayBlock` trait (base/task/thread_pool.h).
///
/// A package never builds its own runner: its owner passes one by `init`. In the macOS app that is the app's one
/// `BackgroundWork` (CmuxNextCompat's `SharedMayBlockRunner` adapts it); tests pass a fake. Callers use the overloads
/// in the extension, which take the call site from `#fileID` and `#line`.
///
/// ```swift
/// let bytes = try await runner.runFiles(.userVisible) { try blockingCall(.fileIO) { try read(path) } }
/// runner.postFiles(.bestEffort, shutdown: .blockShutdown) { save(snapshot) }
/// ```
public protocol MayBlockRunner: Sendable {
    /// Runs `body` on the files lane (disk reads, writes, listings) at `priority`, boosted to the caller's priority
    /// at the call, and returns its result.
    ///
    /// - Throws: What `body` throws; `CancellationError` when the caller is cancelled before the item starts or
    ///   shutdown dropped it. A started item runs to its end.
    func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                               _ body: @escaping @Sendable () throws -> T) async throws -> T

    /// Runs `body` on the system lane (a synchronous call that waits on a daemon, another process or the network)
    /// and returns its result.
    ///
    /// - Throws: As ``runFiles(_:shutdown:site:_:)``.
    func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                _ body: @escaping @Sendable () throws -> T) async throws -> T

    /// Runs a host name resolution on the system lane, where at most a few run at once so that a hung resolver
    /// never holds every slot, and returns its result.
    ///
    /// - Throws: As ``runFiles(_:shutdown:site:_:)``.
    func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                        _ body: @escaping @Sendable () throws -> T) async throws -> T

    /// Queues `body` on the files lane at `priority` and returns at once; nothing awaits it, so nothing boosts it.
    /// A save whose loss loses data states ``MayBlockShutdown/blockShutdown``.
    func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                   _ body: @escaping @Sendable () -> Void)
}

extension MayBlockRunner {
    /// ``runFiles(_:shutdown:site:_:)`` at the caller's site; the default ``MayBlockShutdown/skipOnShutdown`` is for
    /// reads and work a later launch redoes.
    public func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown = .skipOnShutdown,
                                      fileID: StaticString = #fileID, line: UInt = #line,
                                      _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await runFiles(priority, shutdown: shutdown, site: MayBlockCallSite(fileID: fileID, line: line), body)
    }

    /// ``runSystem(_:shutdown:site:_:)`` at the caller's site; default ``MayBlockShutdown/skipOnShutdown``.
    public func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown = .skipOnShutdown,
                                       fileID: StaticString = #fileID, line: UInt = #line,
                                       _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await runSystem(priority, shutdown: shutdown, site: MayBlockCallSite(fileID: fileID, line: line), body)
    }

    /// ``runHostResolution(_:shutdown:site:_:)`` at the caller's site; default ``MayBlockShutdown/skipOnShutdown``.
    public func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown = .skipOnShutdown,
                                               fileID: StaticString = #fileID, line: UInt = #line,
                                               _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await runHostResolution(priority, shutdown: shutdown, site: MayBlockCallSite(fileID: fileID, line: line), body)
    }

    /// ``postFiles(_:shutdown:site:_:)`` at the caller's site.
    public func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown,
                          fileID: StaticString = #fileID, line: UInt = #line, _ body: @escaping @Sendable () -> Void) {
        postFiles(priority, shutdown: shutdown, site: MayBlockCallSite(fileID: fileID, line: line), body)
    }
}
