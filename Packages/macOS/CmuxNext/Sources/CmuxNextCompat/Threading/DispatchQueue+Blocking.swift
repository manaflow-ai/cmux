public import Dispatch

extension DispatchQueue {
    /// Runs `work` on the queue and waits for it, like `sync(execute:)`, as a checked blocking
    /// call (``blockingCall(_:fileID:line:_:)``): the caller waits for everything queued before it.
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID`.
    ///   - line: The calling code's `#line`.
    ///   - work: The work to run on the queue.
    /// - Returns: What `work` returns.
    /// - Throws: What `work` throws.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingSync<T, Failure: Error>(
        fileID: StaticString = #fileID, line: UInt = #line, execute work: () throws(Failure) -> T
    ) throws(Failure) -> T {
        try blockingCall(.syncWait, fileID: fileID, line: line) { () throws(Failure) -> T in
            try sync { Result(catching: work) }.get()
        }
    }
}

extension DispatchWorkItem {
    /// Waits for the work item, like `wait()`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``).
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingWait(fileID: StaticString = #fileID, line: UInt = #line) {
        blockingCall(.syncWait, fileID: fileID, line: line) { wait() }
    }
}
