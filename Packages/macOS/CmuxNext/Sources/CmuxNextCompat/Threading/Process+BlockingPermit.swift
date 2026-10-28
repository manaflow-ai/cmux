public import Foundation

extension Process {
    /// ``blockingWaitUntilExit(fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingWaitUntilExit(_ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) {
        blockingCall(.processWait, permit, fileID: fileID, line: line) { waitUntilExit() } // concurrency-allow: the checked seam; blockingCall reports a main-thread call
    }

    /// ``blockingRun(fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingRun(_ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.processSpawn, permit, fileID: fileID, line: line) { try run() }
    }
}
