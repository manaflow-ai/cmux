public import Foundation

extension NSCondition {
    /// Waits for a signal, like `wait()`, as a checked blocking call
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

    /// Waits for a signal until `limit`, like `wait(until:)`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``).
    ///
    /// - Parameters:
    ///   - limit: The latest time to wait until.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: Whether a signal came before `limit`.
    @inlinable
    public func blockingWait(until limit: Date, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        assertBlockingAllowed(.syncWait, fileID: fileID, line: line)
        return wait(until: limit)
    }
}
