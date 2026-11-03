public import Foundation

extension Process {
    /// Waits for the process to exit, like `waitUntilExit()`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``). On the main thread `waitUntilExit()` also runs
    /// the run loop, so other main-thread work runs inside the wait (an open ``allowBlocking(_:_:)`` scope
    /// is held back for it). Use `terminationHandler` instead.
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    @inlinable
    public func blockingWaitUntilExit(fileID: StaticString = #fileID, line: UInt = #line) {
        assertBlockingAllowed(.processWait, fileID: fileID, line: line)
        waitUntilExit() // concurrency-allow: the checked seam; assertBlockingAllowed reports a main-thread call
    }

    /// Starts the process, like `run()`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``): a spawn on the main thread stalls it (807 ms for
    /// screen.close, 2026-10-24). Start processes from an actor or a `@concurrent` function.
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `run()` throws.
    @inlinable
    public func blockingRun(fileID: StaticString = #fileID, line: UInt = #line) throws {
        assertBlockingAllowed(.processSpawn, fileID: fileID, line: line)
        try run()
    }
}
