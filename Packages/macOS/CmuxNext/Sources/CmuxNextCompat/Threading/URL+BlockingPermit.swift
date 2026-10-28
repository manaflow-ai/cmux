public import Foundation

extension URL {
    /// ``blockingResourceValues(forKeys:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingResourceValues(forKeys keys: Set<URLResourceKey>, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID,
                                       line: UInt = #line) throws -> URLResourceValues {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try resourceValues(forKeys: keys) }
    }
}
