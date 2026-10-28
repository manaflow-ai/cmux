public import Foundation

extension FileHandle {
    /// ``blockingReadToEnd(fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingReadToEnd(_ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws -> Data? {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try readToEnd() } // concurrency-allow: the checked seam; blockingCall reports a main-thread call
    }

    /// ``blockingRead(upToCount:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingRead(upToCount count: Int, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws -> Data? {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try read(upToCount: count) }
    }

    /// ``blockingAvailableData(fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingAvailableData(_ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Data {
        return blockingCall(.fileIO, permit, fileID: fileID, line: line) { availableData } // concurrency-allow: the checked seam; blockingCall reports a main-thread call
    }

    /// ``blockingReadDataToEndOfFile(fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingReadDataToEndOfFile(_ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) -> Data {
        return blockingCall(.fileIO, permit, fileID: fileID, line: line) { readDataToEndOfFile() } // concurrency-allow: the checked seam; blockingCall reports a main-thread call
    }

    /// ``blockingWrite(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingWrite(_ data: Data, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) {
        blockingCall(.fileIO, permit, fileID: fileID, line: line) { write(data) }
    }

    /// ``blockingWrite(contentsOf:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingWrite<T: DataProtocol>(contentsOf data: T, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try write(contentsOf: data) }
    }

    /// ``blockingForReading(from:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public static func blockingForReading(from url: URL, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws -> FileHandle {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileHandle(forReadingFrom: url) }
    }

    /// ``blockingForWriting(to:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public static func blockingForWriting(to url: URL, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws -> FileHandle {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileHandle(forWritingTo: url) }
    }

    /// ``blockingForUpdating(_:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public static func blockingForUpdating(_ url: URL, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws -> FileHandle {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try FileHandle(forUpdating: url) }
    }

    /// ``blockingSeekToEnd(fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable @discardableResult
    public func blockingSeekToEnd(_ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws -> UInt64 {
        return try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try seekToEnd() }
    }

    /// ``blockingSeek(toOffset:fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingSeek(toOffset offset: UInt64, _ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try seek(toOffset: offset) }
    }

    /// ``blockingSynchronize(fileID:line:)`` in a lane or allowance body: `permit` is the body's ``BlockingPermit``.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingSynchronize(_ permit: borrowing BlockingPermit, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try synchronize() }
    }
}
