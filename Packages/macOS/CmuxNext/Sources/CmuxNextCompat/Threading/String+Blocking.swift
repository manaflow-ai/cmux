public import Foundation

extension String {
    /// Reads a text file, like `String(contentsOf:encoding:)`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``). Read files off the main thread.
    ///
    /// - Parameters:
    ///   - url: The file to read.
    ///   - encoding: The file's text encoding.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `String(contentsOf:encoding:)` throws.
    @inlinable
    public init(blockingContentsOf url: URL, encoding: String.Encoding, fileID: StaticString = #fileID, line: UInt = #line) throws {
        assertBlockingAllowed(.fileIO, fileID: fileID, line: line)
        try self.init(contentsOf: url, encoding: encoding)
    }

    /// Reads a text file and detects its encoding, like `String(contentsOf:)`, as a checked
    /// blocking call (``assertBlockingAllowed(_:fileID:line:)``).
    ///
    /// - Parameters:
    ///   - url: The file to read.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `String(contentsOf:usedEncoding:)` throws.
    @inlinable
    public init(blockingContentsOf url: URL, fileID: StaticString = #fileID, line: UInt = #line) throws {
        assertBlockingAllowed(.fileIO, fileID: fileID, line: line)
        var encoding = String.Encoding.utf8
        try self.init(contentsOf: url, usedEncoding: &encoding)
    }

    /// Reads a text file at a path, like `String(contentsOfFile:encoding:)`, as a checked
    /// blocking call (``assertBlockingAllowed(_:fileID:line:)``).
    ///
    /// - Parameters:
    ///   - path: The file to read.
    ///   - encoding: The file's text encoding.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `String(contentsOfFile:encoding:)` throws.
    @inlinable
    public init(blockingContentsOfFile path: String, encoding: String.Encoding, fileID: StaticString = #fileID, line: UInt = #line) throws {
        assertBlockingAllowed(.fileIO, fileID: fileID, line: line)
        try self.init(contentsOfFile: path, encoding: encoding)
    }
}

extension StringProtocol {
    /// Writes the text to a file, like `write(to:atomically:encoding:)`, as a checked blocking
    /// call (``assertBlockingAllowed(_:fileID:line:)``).
    ///
    /// - Parameters:
    ///   - url: The file to write.
    ///   - useAuxiliaryFile: Write to a temporary file first and rename it.
    ///   - encoding: The text encoding to write.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `write(to:atomically:encoding:)` throws.
    @inlinable
    public func blockingWrite(to url: URL, atomically useAuxiliaryFile: Bool, encoding: String.Encoding, fileID: StaticString = #fileID, line: UInt = #line) throws {
        assertBlockingAllowed(.fileIO, fileID: fileID, line: line)
        try write(to: url, atomically: useAuxiliaryFile, encoding: encoding)
    }
}
