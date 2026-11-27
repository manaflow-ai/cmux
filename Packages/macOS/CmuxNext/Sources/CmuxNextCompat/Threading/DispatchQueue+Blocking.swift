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
        assertBlockingAllowed(.syncWait, fileID: fileID, line: line)
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
        assertBlockingAllowed(.syncWait, fileID: fileID, line: line)
        wait()
    }
}
