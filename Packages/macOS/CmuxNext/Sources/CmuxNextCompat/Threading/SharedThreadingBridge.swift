// Public: SharedMayBlockRunner hands the shared packages CmuxThreading's runner.
public import CmuxThreading
#if DEBUG || CMUX_BLOCKING_CHECKS
#if canImport(Darwin)
internal import Darwin
#else
internal import Glibc
#endif
#endif

/// The app's blocking detector as CmuxThreading's ``CmuxThreading/BlockingCallHook``: a shared package's
/// `blockingCall` is this module's ``blockingCall(_:fileID:line:_:)`` under the app kind of the same name (checked in
/// Debug and bench-checks builds, a trace interval in every build), and a main-thread wait for a CmuxThreading
/// `Mutex` is timed and recorded as a wait for this module's ``Mutex`` is (``MainThreadLockWaitObserver``).
///
/// ``BlockingDetector/forProcess()`` installs it once into `BlockingCallHookSlot.process`, so the composition root
/// that makes the detector also turns on the shared packages' seams; the slot refuses a second install.
struct SharedThreadingBridge: CmuxThreading.BlockingCallHook {
    /// Installs the bridge as the process's CmuxThreading hook.
    ///
    /// - Returns: Whether this call installed it; false when the process slot already held a hook.
    @discardableResult
    static func installForProcess() -> Bool {
        BlockingCallHookSlot.process.install(SharedThreadingBridge())
    }

    func blockingCall<Result, Failure: Error>(
        _ kind: CmuxThreading.BlockingKind, fileID: StaticString, line: UInt, _ body: () throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try CmuxNextCompat.blockingCall(CmuxNextCompat.BlockingKind(kind), fileID: fileID, line: line, body)
    }

    func lockWaitWillBegin() -> UInt64? {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        guard blockingOnMainThread() else { return nil }
        return BlockingViolationTable.active.uptimeNanos()
        #else
        return nil
        #endif
    }

    func lockWaitDidEnd(startedAt start: UInt64) -> UInt64? {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        let table = BlockingViolationTable.active
        let nanos = table.uptimeNanos() &- start
        return nanos > table.lockWaitLimitNanos ? nanos : nil
        #else
        return nil
        #endif
    }

    func lockWaited(fileID: StaticString, line: UInt, nanos: UInt64) {
        #if DEBUG || CMUX_BLOCKING_CHECKS
        BlockingViolationTable.active.mainThreadWaitedForLock(fileID: fileID, line: line, nanos: nanos)
        #endif
    }
}

extension CmuxNextCompat.BlockingKind {
    /// The app kind a shared package's kind is recorded under: the case of the same name and raw value.
    init(_ shared: CmuxThreading.BlockingKind) {
        switch shared {
        case .fileIO: self = .fileIO
        case .fsMetadata: self = .fsMetadata
        case .socketRead: self = .socketRead
        case .socketWrite: self = .socketWrite
        case .syncWait: self = .syncWait
        case .ipcReply: self = .ipcReply
        case .processWait: self = .processWait
        case .processSpawn: self = .processSpawn
        case .processReap: self = .processReap
        case .systemCall: self = .systemCall
        case .systemQuery: self = .systemQuery
        case .sqlite: self = .sqlite
        case .sleep: self = .sleep
        }
    }
}

/// The app's ``MayBlockRunner`` (its one `BackgroundWork`) as CmuxThreading's, for a shared package the composition
/// root builds: the shared package's items run on the same lanes, at the same priority, with the same call site.
///
/// ```swift
/// let store = SharedStore(runner: SharedMayBlockRunner(work))   // AppServices
/// ```
public struct SharedMayBlockRunner: CmuxThreading.MayBlockRunner {
    private let base: any CmuxNextCompat.MayBlockRunner

    /// - Parameter base: The app's runner (AppServices' `BackgroundWork`).
    public init(_ base: any CmuxNextCompat.MayBlockRunner) {
        self.base = base
    }

    public func runFiles<T: Sendable>(_ priority: CmuxThreading.MayBlockPriority, shutdown: CmuxThreading.MayBlockShutdown,
                                      site: CmuxThreading.MayBlockCallSite,
                                      _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await base.runFiles(CmuxNextCompat.MayBlockPriority(priority), shutdown: CmuxNextCompat.MayBlockShutdown(shutdown),
                                site: CmuxNextCompat.MayBlockCallSite(site), body)
    }

    public func runSystem<T: Sendable>(_ priority: CmuxThreading.MayBlockPriority, shutdown: CmuxThreading.MayBlockShutdown,
                                       site: CmuxThreading.MayBlockCallSite,
                                       _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await base.runSystem(CmuxNextCompat.MayBlockPriority(priority), shutdown: CmuxNextCompat.MayBlockShutdown(shutdown),
                                 site: CmuxNextCompat.MayBlockCallSite(site), body)
    }

    public func runHostResolution<T: Sendable>(_ priority: CmuxThreading.MayBlockPriority,
                                               shutdown: CmuxThreading.MayBlockShutdown,
                                               site: CmuxThreading.MayBlockCallSite,
                                               _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await base.runHostResolution(CmuxNextCompat.MayBlockPriority(priority),
                                         shutdown: CmuxNextCompat.MayBlockShutdown(shutdown),
                                         site: CmuxNextCompat.MayBlockCallSite(site), body)
    }

    public func postFiles(_ priority: CmuxThreading.MayBlockPriority, shutdown: CmuxThreading.MayBlockShutdown,
                          site: CmuxThreading.MayBlockCallSite, _ body: @escaping @Sendable () -> Void) {
        base.postFiles(CmuxNextCompat.MayBlockPriority(priority), shutdown: CmuxNextCompat.MayBlockShutdown(shutdown),
                       site: CmuxNextCompat.MayBlockCallSite(site), body)
    }
}

extension CmuxNextCompat.MayBlockPriority {
    /// The app level of a shared package's level: the same one (Chrome's `TaskPriority`).
    init(_ shared: CmuxThreading.MayBlockPriority) {
        switch shared {
        case .idle: self = .idle
        case .bestEffort: self = .bestEffort
        case .userVisible: self = .userVisible
        case .userBlocking: self = .userBlocking
        }
    }
}

extension CmuxNextCompat.MayBlockShutdown {
    /// The app behavior of a shared package's shutdown behavior: the same one (Chrome's `TaskShutdownBehavior`).
    init(_ shared: CmuxThreading.MayBlockShutdown) {
        switch shared {
        case .continueOnShutdown: self = .continueOnShutdown
        case .skipOnShutdown: self = .skipOnShutdown
        case .blockShutdown: self = .blockShutdown
        }
    }
}

extension CmuxNextCompat.MayBlockCallSite {
    /// The same caller's site.
    init(_ shared: CmuxThreading.MayBlockCallSite) {
        self.init(fileID: shared.fileID, line: shared.line)
    }
}
