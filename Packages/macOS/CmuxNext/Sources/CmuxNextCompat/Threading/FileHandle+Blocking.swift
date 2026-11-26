public import Foundation

extension FileHandle {
    /// Reads to the end, like `readToEnd()`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``): on a pipe it waits for the writer to close it.
    ///
    /// - Returns: The bytes read, or nil at the end of the file.
    /// - Throws: What `readToEnd()` throws.
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    @inlinable
    public func blockingReadToEnd(fileID: StaticString = #fileID, line: UInt = #line) throws -> Data? {
        assertBlockingAllowed(.fileIO, fileID: fileID, line: line)
        return try readToEnd() // concurrency-allow: the checked seam; assertBlockingAllowed reports a main-thread call
    }

    /// Reads up to `count` bytes, like `read(upToCount:)`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``).
    ///
    /// - Parameters:
    ///   - count: The most bytes to read.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The bytes read, or nil at the end of the file.
    /// - Throws: What `read(upToCount:)` throws.
    @inlinable
    public func blockingRead(upToCount count: Int, fileID: StaticString = #fileID, line: UInt = #line) throws -> Data? {
        assertBlockingAllowed(.fileIO, fileID: fileID, line: line)
        return try read(upToCount: count)
    }

    /// The bytes available now, like `availableData`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``): with nothing available it waits for a write.
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    @inlinable
    public func blockingAvailableData(fileID: StaticString = #fileID, line: UInt = #line) -> Data {
        assertBlockingAllowed(.fileIO, fileID: fileID, line: line)
        return availableData // concurrency-allow: the checked seam; assertBlockingAllowed reports a main-thread call
    }

    /// Reads to the end, like `readDataToEndOfFile()`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``).
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    @inlinable
    public func blockingReadDataToEndOfFile(fileID: StaticString = #fileID, line: UInt = #line) -> Data {
        assertBlockingAllowed(.fileIO, fileID: fileID, line: line)
        return readDataToEndOfFile() // concurrency-allow: the checked seam; assertBlockingAllowed reports a main-thread call
    }

    /// Writes the bytes, like `write(_:)`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``).
    ///
    /// - Parameters:
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    @inlinable
    public func blockingWrite(_ data: Data, fileID: StaticString = #fileID, line: UInt = #line) {
        assertBlockingAllowed(.fileIO, fileID: fileID, line: line)
        write(data)
    }

    /// Writes the bytes, like `write(contentsOf:)`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``).
    ///
    /// - Parameters:
    ///   - data: The bytes to write.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `write(contentsOf:)` throws.
    @inlinable
    public func blockingWrite<T: DataProtocol>(contentsOf data: T, fileID: StaticString = #fileID, line: UInt = #line) throws {
        assertBlockingAllowed(.fileIO, fileID: fileID, line: line)
        try write(contentsOf: data)
    }
}
