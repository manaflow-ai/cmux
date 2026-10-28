#if DEBUG || CMUX_BLOCKING_CHECKS
// The inlinable checks below call pthread_main_np(), so Darwin is a public import here.
public import Darwin
#endif

/// Runs `body`, a call that blocks, as a checked blocking call: in builds with the detector (Debug, bench and
/// Nightly), `body` on the main thread outside ``allowBlocking(_:_:)`` or on a shared pool thread
/// (``BlockingContext/pool``: the Swift cooperative pool, a GCD root queue) is a violation, and while a
/// violation is recorded its wall time adds to the call site's total and maximum (`debug.blocking` prints
/// `total_ms` and `max_ms`). On a dedicated queue or thread it is allowed. On a `BackgroundWork` lane that may
/// block it is allowed unless `kind` is a sync primitive (``BlockingKind/isSyncPrimitive``), which records a
/// ``BlockingContext/laneSync`` site, timed and never a trap. In Release it is `body` plus the trace hook's load.
///
/// In every build, while a trace records the `task` category, the call is one `task.blocking_call` interval
/// (its kind and site, plans/cmux-next/trace.md) through ``BlockingTraceHook``, as Chrome's `ScopedBlockingCall`
/// writes its `ScopedBlockingCall` trace event (base/threading/scoped_blocking_call.cc). Off, that is one acquiring
/// load and one branch.
///
/// This is cmux's `base::ScopedBlockingCall` (base/threading/scoped_blocking_call.h): Chrome asserts blocking is
/// allowed when the scope opens and, in `IOJankMonitoringWindow` (base/threading/scoped_blocking_call_internal.cc),
/// times the outermost scopes that ran on the UI thread. A call inside a timed call on the main thread counts at
/// its own site without time, so the sites' times add up to main-thread time once. Every seam that wraps a blocking primitive
/// (``Foundation/Data/init(blockingContentsOf:options:fileID:line:)``, ``Foundation/FileManager/checked``,
/// ``Dispatch/DispatchSemaphore/blockingWait(fileID:line:)``, ``Foundation/Process/blockingWaitUntilExit(fileID:line:)``)
/// runs the primitive through it and passes its caller's `#fileID` and `#line`, which name the call site.
///
/// A violation: every checked build records it once per call site by default (Debug: one unified-log line,
/// the Debug menu and `debug.blocking`; bench-checks builds, `-DCMUX_BLOCKING_CHECKS`: `debug.blocking`; a
/// cmux NEXT Nightly, also built with `-DCMUX_BLOCKING_CHECKS`: one public unified-log line of kind + image UUID
/// + offset frames per call site, ``BlockingLogSink``). A Debug build, or a Nightly, started with
/// `CMUX_BLOCKING_TRAP=1` hands the main-thread site to the sink (waiting at most 50 ms), logs one fault and stops
/// the process (the opt-in crash mode); a bench build never stops. A pool violation is recorded the same way (once
/// per site, its own `pool` sites); it traps only in a Debug build started with `CMUX_BLOCKING_TRAP_POOL=1`
/// (Chrome's task_tracker.cc runs a task without `MayBlock()` under `ScopedDisallowBlocking`).
///
/// Off the main thread and off the pool it is the trace hook's load, one `pthread_main_np()` call, one
/// thread-specific read and at most the queue label's compare (on a lane, one test of `kind`), with no clock read.
/// On the main thread a repeat of a known site is one table probe, two clock reads around `body` and three atomic
/// adds; an allowed call is not timed.
///
/// ```swift
/// let bytes = try blockingCall(.fileIO, fileID: fileID, line: line) { try Data(contentsOf: url) }
/// ```
///
/// - Parameters:
///   - kind: What the call waits on.
///   - fileID: The calling code's `#fileID` (a seam passes its own caller's).
///   - line: The calling code's `#line`.
///   - body: The blocking work.
/// - Returns: What `body` returns.
/// - Throws: What `body` throws.
@inlinable @inline(__always)
public func blockingCall<Result, Failure: Error>(
    _ kind: BlockingKind, fileID: StaticString = #fileID, line: UInt = #line, _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
    guard let sink = BlockingTraceHook.recordingSink else {
        return try checkedBlockingCall(kind, fileID: fileID, line: line, body)
    }
    return try sink.interval(kind, fileID: fileID, line: line) { () throws(Failure) -> Result in
        try checkedBlockingCall(kind, fileID: fileID, line: line, body)
    }
}

/// ``blockingCall(_:fileID:line:_:)`` without its trace interval: the detector's check and timing around `body`
/// (Debug, bench-checks and Nightly builds), or `body` alone (Release).
@inlinable @inline(__always)
func checkedBlockingCall<Result, Failure: Error>(
    _ kind: BlockingKind, fileID: StaticString, line: UInt, _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
    #if DEBUG || CMUX_BLOCKING_CHECKS
    guard pthread_main_np() != 0 else {
        guard let context = BlockingContext.offMainViolation(kind) else { return try body() }
        return try BlockingViolationTable.offMainBlockingCall(kind, in: context, fileID: fileID, line: line, body)
    }
    return try BlockingViolationTable.mainThreadBlockingCall(kind, fileID: fileID, line: line, body)
    #else
    return try body()
    #endif
}

/// The check of ``blockingCall(_:fileID:line:_:)`` without a body to time: its site counts calls with no wall
/// time. No seam uses it; a seam runs its primitive through ``blockingCall(_:fileID:line:_:)``. It stays as the
/// bare check that scripts/measure/blocking-checks.sh benches and finds compiled out of Release.
///
/// Off the main thread and off the pool the check is one `pthread_main_np()` call, one thread-specific read and
/// at most the queue label's compare; a repeat of a
/// known call site on the main thread is one table probe and one atomic add.
///
/// - Parameters:
///   - kind: What the call waits on.
///   - fileID: The calling code's `#fileID` (a seam passes its own caller's).
///   - line: The calling code's `#line`.
@inlinable @inline(__always)
public func assertBlockingAllowed(_ kind: BlockingKind, fileID: StaticString = #fileID, line: UInt = #line) {
    #if DEBUG || CMUX_BLOCKING_CHECKS
    if pthread_main_np() != 0 {
        BlockingViolationTable.mainThreadBlocked(kind, fileID: fileID, line: line)
    } else if let context = BlockingContext.offMainViolation(kind) {
        BlockingViolationTable.offMainBlocked(kind, in: context, fileID: fileID, line: line)
    }
    #endif
}

/// Records a ``BlockingKind/priorityInversion`` site at `fileID`:`line` when called on the main thread: the caller
/// (BackgroundWork's awaited `run`) found work stated below `.userBlocking` awaited while a person's input action
/// is open. Record only in every mode, counted without time; off the main thread and inside
/// ``allowBlocking(_:_:)`` it records nothing. Release compiles it to nothing.
///
/// - Parameters:
///   - fileID: The awaiting code's `#fileID`.
///   - line: The awaiting code's `#line`.
@inlinable @inline(__always)
public func recordAwaitedLowPriorityWork(fileID: StaticString, line: UInt) {
    #if DEBUG || CMUX_BLOCKING_CHECKS
    if pthread_main_np() != 0 {
        BlockingViolationTable.mainThreadBlocked(.priorityInversion, fileID: fileID, line: line)
    }
    #endif
}

/// Runs `body` with blocking allowed on the main thread for one reviewed reason
/// (Chrome's `ScopedAllowBlocking`).
///
/// The scope covers only the synchronous `body` on the calling thread: a `Task` started inside it does
/// not inherit it, and while the body runs the main run loop again (a modal panel, `waitUntilExit`,
/// `RunLoop.run(until:)`) the scope is held back, so the other main-thread work that nested run does is
/// still checked. Synchronous callbacks from the body itself (a notification, KVO, a delegate call)
/// share it, as in Chrome. Off the main thread it runs `body` with the thread marked dedicated
/// (``BlockingContext/dedicated``), so a seam in it on a pool thread is not a pool violation, nor a sync primitive
/// in it on a lane a lane-sync one (Chrome's `ScopedAllowBaseSyncPrimitives`). In Release builds it only runs
/// `body`.
///
/// - Parameters:
///   - reason: The reviewed allowance (``BlockingAllowance``); each one is listed with its reason
///     in plans/cmux-next/threading-model.md.
///   - body: The work that blocks.
/// - Returns: What `body` returns.
/// - Throws: What `body` throws.
@inlinable @inline(__always)
public func allowBlocking<Result, Failure: Error>(
    _ reason: BlockingAllowance, _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
    try blockingAllowanceScope(reason, body)
}

/// The scope of both ``allowBlocking(_:_:)`` forms (the permit form gives its body a ``BlockingPermit``).
@inlinable @inline(__always)
func blockingAllowanceScope<Result, Failure: Error>(
    _ reason: BlockingAllowance, _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
    #if DEBUG || CMUX_BLOCKING_CHECKS
    guard pthread_main_np() != 0 else { return try BlockingContext.run(as: .dedicated, body) }
    let table = BlockingViolationTable.active
    let token = table.enterAllowance(reason)
    defer { table.leaveAllowance(token) }
    return try body()
    #else
    return try body()
    #endif
}
