public import Dispatch

/// How much a person waits for one piece of blocking work: Chrome's `base::TaskPriority`
/// (base/task/task_traits.h), for modules that cannot import CmuxNextWakeups.
///
/// The same four levels as CmuxNextWakeups' `WorkPriority`; its ``MayBlockRunner`` conformance maps them one to
/// one, so a lane item runs at `WorkPriority.qos`. ``qos`` here is the QoS of a ``ChildProcessLauncher`` spawn.
public enum MayBlockPriority: Int, Sendable, Comparable, CaseIterable {
    /// Nobody waits for it (indexing, cache cleanup); QoS `.background`.
    case idle
    /// A person does not wait for it now (saves, automation); QoS `.utility`.
    case bestEffort
    /// Its result shows on screen soon (an icon, a file a page shows); a spawn at QoS `.default`.
    case userVisible
    /// A person waits for it right now (the result of a key, a click or an open); QoS `.userInitiated`.
    case userBlocking

    /// The GCD quality of service a ``ChildProcessLauncher`` spawns children of this level at, never
    /// `.userInteractive`. ``userVisible`` stays `.default`, as CmuxNextWakeups' `WorkPriority.processQoS`: a child's
    /// priority follows what it shows (Chrome's `RenderProcessHostImpl::UpdateProcessPriority`), not the thread
    /// pool's `kDefault` mapping, so a person's `!` command from an agent pane never competes with user-blocking work.
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

/// Where a ``MayBlockRunner`` item was posted: the caller's `#fileID` and `#line`, which name a slow
/// ``MayBlockShutdown/blockShutdown`` item in Debug (BackgroundWork's overrun record).
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

/// Runs work that may block off the main thread and off Swift's cooperative pool, for a module below
/// CmuxNextWakeups: Chrome's `base::ThreadPool::PostTask` with the `MayBlock` trait
/// (base/task/thread_pool.h), cut to the two lanes those modules use.
///
/// The app's one `BackgroundWork` conforms. The composition root (AppServices) passes it by `init`; a module
/// never builds its own runner. Tests pass a fake or their own `BackgroundWork`.
///
/// Callers use the overloads in the extension, which take the call site from `#fileID` and `#line`; the
/// requirements take it as a ``MayBlockCallSite``.
///
/// ```swift
/// let bytes = try await runner.runFiles(.userVisible) { try read(url) }
/// let addresses = try await runner.runHostResolution(.userVisible) { resolve(host) }  // blockingGetaddrinfo inside
/// runner.postFiles(.bestEffort, shutdown: .blockShutdown) { try? save(snapshot) }
/// ```
public protocol MayBlockRunner: Sendable {
    /// Runs `body` on the files lane (disk reads, writes, listings) at `priority`, boosted to the caller's
    /// priority at the call, and returns its result.
    ///
    /// - Throws: what `body` throws; `CancellationError` when the caller is cancelled before the item
    ///   starts or shutdown dropped it. A started item runs to its end.
    func runFiles<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                               _ body: @escaping @Sendable () throws -> T) async throws -> T

    /// Runs `body` on the system lane (a synchronous call that waits on a daemon, another process or the
    /// network: Security, Launch Services, host resolution) and returns its result.
    ///
    /// - Throws: as ``runFiles(_:shutdown:site:_:)``.
    func runSystem<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                _ body: @escaping @Sendable () throws -> T) async throws -> T

    /// Runs a host name resolution (`blockingGetaddrinfo`) on the system lane and returns its result. At most
    /// four run at once there, never on its reserved slot, so a hung resolver never holds the slots keychain or
    /// Accessibility work needs. The cap is cmux's: Chrome gives DNS a pool of its own (net/dns/host_resolver_manager.cc).
    ///
    /// - Throws: as ``runFiles(_:shutdown:site:_:)``.
    func runHostResolution<T: Sendable>(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                                        _ body: @escaping @Sendable () throws -> T) async throws -> T

    /// Queues `body` on the files lane at `priority` and returns at once; nothing awaits it, so nothing
    /// boosts it. A save whose loss loses data states ``MayBlockShutdown/blockShutdown``.
    func postFiles(_ priority: MayBlockPriority, shutdown: MayBlockShutdown, site: MayBlockCallSite,
                   _ body: @escaping @Sendable () -> Void)
}

extension MayBlockRunner {
    /// ``runFiles(_:shutdown:site:_:)`` at the caller's site; the default ``MayBlockShutdown/skipOnShutdown`` is
    /// for reads and work a later launch redoes.
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
