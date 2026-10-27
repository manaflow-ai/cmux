public import Dispatch

extension DispatchSemaphore {
    /// Waits for the semaphore, like `wait()`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``): never wait on the main thread.
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    @inlinable
    public func blockingWait(fileID: StaticString = #fileID, line: UInt = #line) {
        blockingCall(.syncWait, fileID: fileID, line: line) { wait() }
    }

    /// Waits for the semaphore until `timeout`, like `wait(timeout:)`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``).
    ///
    /// - Parameters:
    ///   - timeout: The latest time to wait until.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: Whether the semaphore was signaled before `timeout`.
    @inlinable @discardableResult
    public func blockingWait(timeout: DispatchTime, fileID: StaticString = #fileID, line: UInt = #line) -> DispatchTimeoutResult {
        return blockingCall(.syncWait, fileID: fileID, line: line) { wait(timeout: timeout) }
    }
}
