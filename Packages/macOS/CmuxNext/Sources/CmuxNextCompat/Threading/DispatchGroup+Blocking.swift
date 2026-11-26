public import Dispatch

extension DispatchGroup {
    /// Waits for the group, like `wait()`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``). Prefer `notify(queue:execute:)`.
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    @inlinable
    public func blockingWait(fileID: StaticString = #fileID, line: UInt = #line) {
        assertBlockingAllowed(.syncWait, fileID: fileID, line: line)
        wait()
    }

    /// Waits for the group until `timeout`, like `wait(timeout:)`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``).
    ///
    /// - Parameters:
    ///   - timeout: The latest time to wait until.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: Whether the group finished before `timeout`.
    @inlinable @discardableResult
    public func blockingWait(timeout: DispatchTime, fileID: StaticString = #fileID, line: UInt = #line) -> DispatchTimeoutResult {
        assertBlockingAllowed(.syncWait, fileID: fileID, line: line)
        return wait(timeout: timeout)
    }
}
