#if DEBUG || CMUX_BLOCKING_CHECKS
// The inlinable checks below call pthread_main_np(), so Darwin is a public import here.
public import Darwin
#endif

/// Runs `body`, a call that blocks, as a checked blocking call: in builds with the detector (Debug, bench, and
/// Nightly to come), `body` on the main thread outside ``allowBlocking(_:_:)`` is a violation, and while a
/// violation is recorded its wall time adds to the call site's total and maximum (`debug.blocking` prints
/// `total_ms` and `max_ms`). In Release it is `body` alone.
///
/// This is cmux's `base::ScopedBlockingCall` (base/threading/scoped_blocking_call.h): Chrome asserts blocking is
/// allowed when the scope opens and, in `IOJankMonitoringWindow` (base/threading/scoped_blocking_call_internal.cc),
/// times the scopes that ran on the UI thread. Every seam that wraps a blocking primitive
/// (``Foundation/Data/init(blockingContentsOf:options:fileID:line:)``, ``Foundation/FileManager/checked``,
/// ``Dispatch/DispatchSemaphore/blockingWait(fileID:line:)``, ``Foundation/Process/blockingWaitUntilExit(fileID:line:)``)
/// runs the primitive through it and passes its caller's `#fileID` and `#line`, which name the call site.
///
/// A violation: Debug records it once per call site (one unified-log line, the Debug menu and
/// `debug.blocking`), or stops the process when it was started with `CMUX_BLOCKING_TRAP=1`. Bench
/// builds (`-DCMUX_BLOCKING_CHECKS`) record it for `debug.blocking`. To come: a Nightly built with
/// `-DCMUX_BLOCKING_CHECKS` will record it and continue, and send it to the opt-in hang reports once
/// their sink is installed.
///
/// Off the main thread it is one `pthread_main_np()` call and one branch, with no clock read. On the main thread
/// a repeat of a known site is one table probe, one atomic add and two clock reads around `body`; an allowed call
/// is not timed.
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
    #if DEBUG || CMUX_BLOCKING_CHECKS
    guard pthread_main_np() != 0 else { return try body() }
    return try BlockingViolationTable.mainThreadBlockingCall(kind, fileID: fileID, line: line, body)
    #else
    return try body()
    #endif
}

/// Marks a call that blocks where the blocking work is not a closure (``Mutex``'s lock wait): the check of
/// ``blockingCall(_:fileID:line:_:)`` without the timing, so its site counts calls only. A seam that wraps a
/// blocking primitive uses ``blockingCall(_:fileID:line:_:)`` instead.
///
/// Off the main thread the check is one `pthread_main_np()` call and one branch; a repeat of a
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
/// share it, as in Chrome. Off the main thread, and in Release builds, it only runs `body`.
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
    #if DEBUG || CMUX_BLOCKING_CHECKS
    guard pthread_main_np() != 0 else { return try body() }
    let table = BlockingViolationTable.active
    let token = table.enterAllowance(reason)
    defer { table.leaveAllowance(token) }
    return try body()
    #else
    return try body()
    #endif
}
