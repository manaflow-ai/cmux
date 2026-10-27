public import Foundation

extension Data {
    /// Reads a file, like `Data(contentsOf:options:)`, as a checked blocking call: in Debug and
    /// bench-checks builds (Nightly to come) the main-thread blocking detector reports it on the main thread
    /// (``blockingCall(_:fileID:line:_:)``). Read files off the main thread.
    ///
    /// - Parameters:
    ///   - url: The file to read.
    ///   - options: Foundation's reading options.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `Data(contentsOf:options:)` throws.
    @inlinable
    public init(blockingContentsOf url: URL, options: Data.ReadingOptions = [], fileID: StaticString = #fileID, line: UInt = #line) throws {
        self = try blockingCall(.fileIO, fileID: fileID, line: line) { try Data(contentsOf: url, options: options) }
    }

    /// Writes the bytes to a file, like `write(to:options:)`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``).
    ///
    /// - Parameters:
    ///   - url: The file to write.
    ///   - options: Foundation's writing options.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `write(to:options:)` throws.
    @inlinable
    public func blockingWrite(to url: URL, options: Data.WritingOptions = [], fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try write(to: url, options: options) }
    }
}
