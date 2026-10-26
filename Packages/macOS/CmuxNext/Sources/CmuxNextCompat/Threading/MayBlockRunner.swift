public import Dispatch

/// How much a person waits for one piece of blocking work: Chrome's `base::TaskPriority`
/// (base/task/task_traits.h), for modules that cannot import CmuxNextWakeups.
///
/// The same four levels and the same QoS as CmuxNextWakeups' `WorkPriority`; its ``MayBlockRunner``
/// conformance maps them one to one.
public enum MayBlockPriority: Int, Sendable, Comparable, CaseIterable {
    /// Nobody waits for it (indexing, cache cleanup); QoS `.background`.
    case idle
    /// A person does not wait for it now (saves, automation); QoS `.utility`.
    case bestEffort
    /// Its result shows on screen soon (an icon, a file a page shows); QoS `.default`.
    case userVisible
    /// A person waits for it right now (the result of a key, a click or an open); QoS `.userInitiated`.
    case userBlocking

    /// The GCD quality of service a lane runs this level's work at, never `.userInteractive`.
    public var qos: DispatchQoS {
        switch self {
        case .userBlocking: .userInitiated
        case .userVisible: .default
        case .bestEffort: .utility
        case .idle: .background
        }
    }

    public static func < (lhs: MayBlockPriority, rhs: MayBlockPriority) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What quit does with an item: Chrome's `TaskShutdownBehavior`, as CmuxNextWakeups' `ShutdownBehavior`.
public enum MayBlockShutdown: Sendable {
    /// Keep running if it has started; drop it if it has not. Quit does not wait for it.
    case continueOnShutdown
    /// Drop it if it has not started (a `run` caller gets `CancellationError`); quit does not wait.
    case skipOnShutdown
    /// Quit waits for it: one short save whose loss loses a person's data.
    case blockShutdown
}

/// Runs work that may block off the main thread and off Swift's cooperative pool, for a module below
/// CmuxNextWakeups: Chrome's `base::ThreadPool::PostTask` with the `MayBlock` trait
/// (base/task/thread_pool.h), cut to the two lanes those modules use.
///
/// The app's one `BackgroundWork` conforms. The composition root (AppServices) passes it by `init`; a module
/// never builds its own runner. Tests pass a fake or their own `BackgroundWork`.
///
/// ```swift
/// let bytes = try await runner.runFiles(.userVisible) { try read(url) }
/// runner.postFiles(.bestEffort, shutdown: .blockShutdown) { try? save(snapshot) }
/// ```
public protocol MayBlockRunner: Sendable {
    /// Runs `body` on the files lane (disk reads, writes, listings) at `priority`, boosted to the caller's
    /// priority at the call, and returns its result.
    ///
    /// - Throws: what `body` throws; `CancellationError` when the caller is cancelled before the item
    ///   starts or shutdown dropped it. A started item runs to its end.
    func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown,
                               _ body: @escaping @Sendable () throws -> T) async throws -> T

    /// Runs `body` on the system lane (a synchronous call that waits on a daemon, another process or the
    /// network: Security, Launch Services, host resolution) and returns its result.
    ///
    /// - Throws: as ``runFiles(_:shutdown:_:)``.
    func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown,
                                _ body: @escaping @Sendable () throws -> T) async throws -> T

    /// Queues `body` on the files lane at `priority` and returns at once; nothing awaits it, so nothing
    /// boosts it. A save whose loss loses data states ``MayBlockShutdown/blockShutdown``.
    func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, _ body: @escaping @Sendable () -> Void)
}

extension MayBlockRunner {
    /// ``runFiles(_:shutdown:_:)`` with ``MayBlockShutdown/skipOnShutdown``: reads and work a later launch redoes.
    public func runFiles<T: Sendable>(_ priority: MayBlockPriority,
                                      _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await runFiles(priority, shutdown: .skipOnShutdown, body)
    }

    /// ``runSystem(_:shutdown:_:)`` with ``MayBlockShutdown/skipOnShutdown``.
    public func runSystem<T: Sendable>(_ priority: MayBlockPriority,
                                       _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await runSystem(priority, shutdown: .skipOnShutdown, body)
    }
}
