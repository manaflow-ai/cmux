internal import CmuxSafeConcurrency

/// What the process does with a shared package's checked blocking calls and contended ``Mutex`` waits: the app's
/// blocking detector, installed once at launch into ``BlockingCallHookSlot/process`` (CmuxNextCompat's
/// `SharedThreadingBridge`). Until one is installed, and in a process that installs none (the iOS app, a package's
/// tests), a blocking call is its body and a wait is untimed.
///
/// Chrome's `ScopedBlockingCall` reaches the process's blocking observer and its `IOJankMonitoringWindow` the same
/// way from every component (base/threading/scoped_blocking_call_internal.cc).
public protocol BlockingCallHook: Sendable {
    /// Runs `body`, a call that blocks, as one checked blocking call of `kind` at `fileID`:`line`, and returns its
    /// result.
    ///
    /// - Throws: What `body` throws.
    func blockingCall<Result, Failure: Error>(
        _ kind: BlockingKind, fileID: StaticString, line: UInt, _ body: () throws(Failure) -> Result
    ) throws(Failure) -> Result

    /// The calling thread is about to wait for a ``Mutex`` another thread holds. Returns the wait's start, in the
    /// hook's clock (nanoseconds), to time it; nil leaves it untimed (the detector times only the main thread).
    func lockWaitWillBegin() -> UInt64?

    /// The timed wait that began at `start` ended with the lock held. Returns its length (nanoseconds) when it is
    /// long enough to record once the lock is released, else nil. Keep it short: the lock is held.
    func lockWaitDidEnd(startedAt start: UInt64) -> UInt64?

    /// Records a wait of `nanos` for the ``Mutex`` locked at `fileID`:`line`; called after the lock was released.
    func lockWaited(fileID: StaticString, line: UInt, nanos: UInt64)
}

/// Where a process keeps its ``BlockingCallHook``: none until ``install(_:)``, then the first one installed, for the
/// life of the process (a second install is refused, so the hook the launch installed is the one every call sees).
///
/// ```swift
/// BlockingCallHookSlot.process.install(SharedThreadingBridge())   // CmuxNextCompat, once at launch
/// let bytes = try blockingCall(.fileIO) { try read(path) }        // any shared package, any thread
/// ```
public final class BlockingCallHookSlot: Sendable {
    /// The process's slot, which ``blockingCall(_:fileID:line:_:)`` and ``Mutex`` read.
    // singleton-allow: blockingCall is a free function every shared package calls on any thread, inside locks and before any composition root exists, so it has no instance to take its hook through; Chrome's ScopedBlockingCall reads the process-wide blocking observer.
    // lint:allow singleton: the shared blocking-call hook exception in plans/cmux-next/arch-ratchet.json (2026-10-26).
    public static let process = BlockingCallHookSlot()

    /// The installed hook. CmuxSafeConcurrency's mutex, not this module's ``Mutex``: a contended wait for this lock
    /// must not read this slot again.
    private let hook = CmuxSafeConcurrency.Mutex<(any BlockingCallHook)?>(nil)

    /// An empty slot (tests; the process uses ``process``).
    public init() {}

    /// Installs `hook` when the slot has none.
    ///
    /// - Parameter hook: The process's blocking detector.
    /// - Returns: Whether `hook` was installed; false when the slot already holds one, which stays.
    @discardableResult
    public func install(_ hook: any BlockingCallHook) -> Bool {
        self.hook.withLock { installed in
            guard installed == nil else { return false }
            installed = hook
            return true
        }
    }

    /// Whether a hook is installed.
    public var isInstalled: Bool {
        installed != nil
    }

    /// The installed hook, nil before ``install(_:)``.
    var installed: (any BlockingCallHook)? {
        hook.withLock { $0 }
    }

    /// Runs `body` as one checked blocking call through the installed hook, or alone when none is installed.
    ///
    /// - Parameters:
    ///   - kind: What the call waits on.
    ///   - fileID: The calling code's `#fileID` (a wrapper passes its own caller's).
    ///   - line: The calling code's `#line`.
    ///   - body: The blocking work.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    public func blockingCall<Result, Failure: Error>(
        _ kind: BlockingKind, fileID: StaticString = #fileID, line: UInt = #line, _ body: () throws(Failure) -> Result
    ) throws(Failure) -> Result {
        guard let hook = installed else { return try body() }
        return try hook.blockingCall(kind, fileID: fileID, line: line, body)
    }
}

/// Runs `body`, a call that blocks, as a checked blocking call: the seam of a shared package, as CmuxNextCompat's
/// `blockingCall` is the app's (Chrome's `base::ScopedBlockingCall`, base/threading/scoped_blocking_call.h). In the
/// app the hook it installed at launch checks it (a call on the main thread or a shared pool thread is a violation in
/// Debug) and writes it to a recording trace; elsewhere it is `body`.
///
/// It marks the call; it does not move it. Code that may run on the main thread or the cooperative pool runs its
/// blocking work through the ``MayBlockRunner`` it was given.
///
/// ```swift
/// let bytes = try blockingCall(.fileIO) { try Data(contentsOf: url) }
/// ```
///
/// - Parameters:
///   - kind: What the call waits on.
///   - fileID: The calling code's `#fileID` (a wrapper passes its own caller's).
///   - line: The calling code's `#line`.
///   - body: The blocking work.
/// - Returns: What `body` returns.
/// - Throws: What `body` throws.
public func blockingCall<Result, Failure: Error>(
    _ kind: BlockingKind, fileID: StaticString = #fileID, line: UInt = #line, _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
    try BlockingCallHookSlot.process.blockingCall(kind, fileID: fileID, line: line, body)
}
