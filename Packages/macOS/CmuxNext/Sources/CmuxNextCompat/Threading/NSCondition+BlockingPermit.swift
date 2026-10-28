public import Foundation

extension NSCondition {
    /// ``blockingWait(fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingWait(_ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) {
        blockingCall(.syncWait, permit, fileID: fileID, line: line) { wait() }
    }

    /// ``blockingWait(until:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingWait(until limit: Date, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Bool {
        return blockingCall(.syncWait, permit, fileID: fileID, line: line) { wait(until: limit) }
    }
}
