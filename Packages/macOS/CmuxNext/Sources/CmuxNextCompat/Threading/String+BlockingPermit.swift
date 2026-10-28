public import Foundation

extension String {
    /// ``init(blockingContentsOf:encoding:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public init(blockingContentsOf url: URL, encoding: String.Encoding, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        self = try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try String(contentsOf: url, encoding: encoding) }
    }

    /// ``init(blockingContentsOf:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public init(blockingContentsOf url: URL, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        self = try blockingCall(.fileIO, permit, fileID: fileID, line: line) {
            var encoding = String.Encoding.utf8
            return try String(contentsOf: url, usedEncoding: &encoding)
        }
    }

    /// ``init(blockingContentsOfFile:encoding:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public init(blockingContentsOfFile path: String, encoding: String.Encoding, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        self = try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try String(contentsOfFile: path, encoding: encoding) }
    }
}

extension StringProtocol {
    /// ``blockingWrite(to:atomically:encoding:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingWrite(to url: URL, atomically useAuxiliaryFile: Bool, encoding: String.Encoding, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try write(to: url, atomically: useAuxiliaryFile, encoding: encoding) }
    }
}
