public import Dispatch

extension DispatchGroup {
    /// ``blockingWait(fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingWait(_ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) {
        blockingCall(.syncWait, permit, fileID: fileID, line: line) { wait() }
    }

    /// ``blockingWait(timeout:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable @discardableResult
    public func blockingWait(timeout: DispatchTime, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> DispatchTimeoutResult {
        return blockingCall(.syncWait, permit, fileID: fileID, line: line) { wait(timeout: timeout) }
    }
}
