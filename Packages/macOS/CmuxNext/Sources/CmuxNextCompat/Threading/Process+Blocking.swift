public import Foundation

extension Process {
    /// Waits for the process to exit, like `waitUntilExit()`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``). On the main thread `waitUntilExit()` also runs
    /// the run loop, so other main-thread work runs inside the wait (an open ``allowBlocking(_:_:)`` scope
    /// is held back for it). Use `terminationHandler` instead.
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    @inlinable
    public func blockingWaitUntilExit(fileID: StaticString = #fileID, line: UInt = #line) {
        blockingCall(.processWait, fileID: fileID, line: line) { waitUntilExit() } // concurrency-allow: the checked seam; blockingCall reports a main-thread call
    }

    /// Starts the process, like `run()`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``): a spawn on the main thread stalls it (807 ms for
    /// screen.close, 2026-10-24). Start processes from an actor or a `@concurrent` function.
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `run()` throws.
    @inlinable
    public func blockingRun(fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.processSpawn, fileID: fileID, line: line) { try run() }
    }
}
