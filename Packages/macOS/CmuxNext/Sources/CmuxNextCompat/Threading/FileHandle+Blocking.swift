public import Foundation

extension FileHandle {
    /// Reads to the end, like `readToEnd()`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``): on a pipe it waits for the writer to close it.
    ///
    /// - Returns: The bytes read, or nil at the end of the file.
    /// - Throws: What `readToEnd()` throws.
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    @inlinable
    public func blockingReadToEnd(fileID: StaticString = #fileID, line: UInt = #line) throws -> Data? {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try readToEnd() } // concurrency-allow: the checked seam; blockingCall reports a main-thread call
    }

    /// Reads up to `count` bytes, like `read(upToCount:)`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``).
    ///
    /// - Parameters:
    ///   - count: The most bytes to read.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The bytes read, or nil at the end of the file.
    /// - Throws: What `read(upToCount:)` throws.
    @inlinable
    public func blockingRead(upToCount count: Int, fileID: StaticString = #fileID, line: UInt = #line) throws -> Data? {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try read(upToCount: count) }
    }

    /// The bytes available now, like `availableData`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``): with nothing available it waits for a write.
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    @inlinable
    public func blockingAvailableData(fileID: StaticString = #fileID, line: UInt = #line) -> Data {
        return blockingCall(.fileIO, fileID: fileID, line: line) { availableData } // concurrency-allow: the checked seam; blockingCall reports a main-thread call
    }

    /// Reads to the end, like `readDataToEndOfFile()`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``).
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    @inlinable
    public func blockingReadDataToEndOfFile(fileID: StaticString = #fileID, line: UInt = #line) -> Data {
        return blockingCall(.fileIO, fileID: fileID, line: line) { readDataToEndOfFile() } // concurrency-allow: the checked seam; blockingCall reports a main-thread call
    }

    /// Writes the bytes, like `write(_:)`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``).
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    @inlinable
    public func blockingWrite(_ data: Data, fileID: StaticString = #fileID, line: UInt = #line) {
        blockingCall(.fileIO, fileID: fileID, line: line) { write(data) }
    }

    /// Writes the bytes, like `write(contentsOf:)`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``).
    ///
    /// - Parameters:
    ///   - data: The bytes to write.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `write(contentsOf:)` throws.
    @inlinable
    public func blockingWrite<T: DataProtocol>(contentsOf data: T, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try write(contentsOf: data) }
    }

    /// Opens a file for reading, like `FileHandle(forReadingFrom:)`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``, as Chrome's `base::File` opens under a `ScopedBlockingCall`).
    ///
    /// - Parameters:
    ///   - url: The file.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The open handle.
    /// - Throws: What `FileHandle(forReadingFrom:)` throws.
    @inlinable
    public static func blockingForReading(from url: URL, fileID: StaticString = #fileID, line: UInt = #line) throws -> FileHandle {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try FileHandle(forReadingFrom: url) }
    }

    /// Opens a file for writing, like `FileHandle(forWritingTo:)`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``).
    ///
    /// - Parameters:
    ///   - url: The file, which must exist.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The open handle.
    /// - Throws: What `FileHandle(forWritingTo:)` throws.
    @inlinable
    public static func blockingForWriting(to url: URL, fileID: StaticString = #fileID, line: UInt = #line) throws -> FileHandle {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try FileHandle(forWritingTo: url) }
    }

    /// Opens a file for reading and writing, like `FileHandle(forUpdating:)`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``).
    ///
    /// - Parameters:
    ///   - url: The file, which must exist.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The open handle.
    /// - Throws: What `FileHandle(forUpdating:)` throws.
    @inlinable
    public static func blockingForUpdating(_ url: URL, fileID: StaticString = #fileID, line: UInt = #line) throws -> FileHandle {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try FileHandle(forUpdating: url) }
    }

    /// Moves to the end of the file, like `seekToEnd()`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``).
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The new offset.
    /// - Throws: What `seekToEnd()` throws.
    @inlinable @discardableResult
    public func blockingSeekToEnd(fileID: StaticString = #fileID, line: UInt = #line) throws -> UInt64 {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try seekToEnd() }
    }

    /// Moves to `offset`, like `seek(toOffset:)`, as a checked blocking call (``blockingCall(_:fileID:line:_:)``).
    ///
    /// - Parameters:
    ///   - offset: The new offset from the start of the file.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `seek(toOffset:)` throws.
    @inlinable
    public func blockingSeek(toOffset offset: UInt64, fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try seek(toOffset: offset) }
    }

    /// Flushes the file to the disk, like `synchronize()`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``): it waits for the disk.
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `synchronize()` throws.
    @inlinable
    public func blockingSynchronize(fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try synchronize() }
    }
}
