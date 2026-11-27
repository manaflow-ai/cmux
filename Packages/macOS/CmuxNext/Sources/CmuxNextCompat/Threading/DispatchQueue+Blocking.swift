#if DEBUG || CMUX_BLOCKING_CHECKS
public import Darwin
#endif
public import Dispatch

extension DispatchQueue {
    /// Runs `work` on the queue and waits for it, like `sync(execute:)`, as a checked blocking
    /// call (``assertBlockingAllowed(_:fileID:line:)``): the caller waits for everything queued before it.
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID`.
    ///   - line: The calling code's `#line`.
    ///   - work: The work to run on the queue.
    /// - Returns: What `work` returns.
    /// - Throws: What `work` throws.
    @inlinable
    public func blockingSync<T>(fileID: StaticString = #fileID, line: UInt = #line, execute work: () throws -> T) rethrows -> T {
        // Not through blockingCall: a rethrows function may only call functions that rethrow its own closure.
        #if DEBUG || CMUX_BLOCKING_CHECKS
        assertBlockingAllowed(.syncWait, fileID: fileID, line: line)
        guard pthread_main_np() != 0 else { return try sync(execute: work) }
        let previous = BlockingOpenCall.enter(.syncWait, fileID: fileID, line: line)
        defer { BlockingOpenCall.leave(previous) }
        #endif
        return try sync(execute: work)
    }
}

extension DispatchWorkItem {
    /// Waits for the work item, like `wait()`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``).
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    @inlinable
    public func blockingWait(fileID: StaticString = #fileID, line: UInt = #line) {
        blockingCall(.syncWait, fileID: fileID, line: line) { wait() }
    }
}
