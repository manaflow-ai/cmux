#if DEBUG || CMUX_BLOCKING_CHECKS
// The inlinable checks below call pthread_main_np(), so Darwin is a public import here.
public import Darwin
#endif

/// Marks a call that blocks: in builds with the detector (Debug, bench and Nightly), a blocking call on the main thread
/// outside ``allowBlocking(_:_:)`` is a violation; in Release this compiles to nothing.
///
/// This is cmux's `base::ScopedBlockingCall` (Chrome's `AssertBlockingAllowed`). It belongs in
/// the seams that wrap blocking primitives (``Foundation/Data/init(blockingContentsOf:options:fileID:line:)``,
/// ``Foundation/FileManager/checked``, ``Dispatch/DispatchSemaphore/blockingWait(fileID:line:)``,
/// ``Foundation/Process/blockingWaitUntilExit(fileID:line:)``, ``Mutex``), not at call sites;
/// each seam passes its caller's `#fileID` and `#line`, which name the call site.
///
/// A violation: Debug records it once per call site (one unified-log line, the Debug menu and
/// `debug.blocking`), or stops the process when it was started with `CMUX_BLOCKING_TRAP=1`. Bench
/// builds (`-DCMUX_BLOCKING_CHECKS`) record it for `debug.blocking`. A cmux NEXT Nightly (also built with
/// `-DCMUX_BLOCKING_CHECKS`) records it and continues: one public unified-log line of kind + image UUID +
/// offset frames per call site (``BlockingLogSink``); the opt-in hang reports do not carry it yet.
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

/// Runs `body`, a call that blocks, as a checked blocking call: ``assertBlockingAllowed(_:fileID:line:)``, and
/// while `body` runs on the main thread the call is open for the hang watcher (``BlockingOpenCall``), so a stall
/// or hang that `body` causes names its kind and call site (`blocking_call` in `debug.hangs`, the hang file's
/// `blocking call:` line). This is Chrome's `ScopedBlockingCall` scope, which `HangWatcher` reports.
///
/// In the builds with the detector (Debug, bench, Nightly) the open call is a few atomic stores on each side of
/// `body`, on the main thread only; off the main thread it is one `pthread_main_np()` call and `body`. In Release
/// it is `body`.
///
/// ```swift
/// try blockingCall(.fileIO, fileID: fileID, line: line) { try FileManager.default.removeItem(at: url) }
/// ```
///
/// - Parameters:
///   - kind: What the call waits on.
///   - fileID: The calling code's `#fileID` (a seam passes its own caller's).
///   - line: The calling code's `#line`.
///   - body: The blocking primitive.
/// - Returns: What `body` returns.
/// - Throws: What `body` throws.
@inlinable @inline(__always)
public func blockingCall<Result, Failure: Error>(
    _ kind: BlockingKind, fileID: StaticString = #fileID, line: UInt = #line, _ body: () throws(Failure) -> Result
) throws(Failure) -> Result {
    #if DEBUG || CMUX_BLOCKING_CHECKS
    guard pthread_main_np() != 0 else { return try body() }
    assertBlockingAllowed(kind, fileID: fileID, line: line)
    let previous = BlockingOpenCall.enter(kind, fileID: fileID, line: line)
    defer { BlockingOpenCall.leave(previous) }
    return try body()
    #else
    return try body()
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
