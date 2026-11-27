public import Foundation

extension Data {
    /// Reads a file, like `Data(contentsOf:options:)`, as a checked blocking call: in Debug and
    /// bench and Nightly builds the main-thread blocking detector reports it on the main thread
    /// (``assertBlockingAllowed(_:fileID:line:)``). Read files off the main thread.
    ///
    /// - Parameters:
    ///   - url: The file to read.
    ///   - options: Foundation's reading options.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `Data(contentsOf:options:)` throws.
    @inlinable
    public init(blockingContentsOf url: URL, options: Data.ReadingOptions = [], fileID: StaticString = #fileID, line: UInt = #line) throws {
        assertBlockingAllowed(.fileIO, fileID: fileID, line: line)
        try self.init(contentsOf: url, options: options)
    }

    /// Writes the bytes to a file, like `write(to:options:)`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``).
    ///
    /// - Parameters:
    ///   - url: The file to write.
    ///   - options: Foundation's writing options.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `write(to:options:)` throws.
    @inlinable
    public func blockingWrite(to url: URL, options: Data.WritingOptions = [], fileID: StaticString = #fileID, line: UInt = #line) throws {
        assertBlockingAllowed(.fileIO, fileID: fileID, line: line)
        try write(to: url, options: options)
    }
}
