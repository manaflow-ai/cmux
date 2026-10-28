public import Dispatch

extension DispatchQueue {
    /// ``blockingSync(fileID:line:execute:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingSync<T, Failure: Error>(
        _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line, execute work: () throws(Failure) -> T
    ) throws(Failure) -> T {
        try blockingCall(.syncWait, permit, fileID: fileID, line: line) { () throws(Failure) -> T in
            try sync { Result(catching: work) }.get()
        }
    }
}

extension DispatchWorkItem {
    /// ``blockingWait(fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingWait(_ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) {
        blockingCall(.syncWait, permit, fileID: fileID, line: line) { wait() }
    }
}
