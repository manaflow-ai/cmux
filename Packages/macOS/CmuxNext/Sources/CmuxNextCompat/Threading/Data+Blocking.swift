public import Foundation

extension Data {
    /// Reads a file, like `Data(contentsOf:options:)`, as a checked blocking call: in Debug and
    /// bench-checks and Nightly builds the main-thread blocking detector reports it on the main thread
    /// (``blockingCall(_:fileID:line:_:)``). Read files off the main thread. Deprecated: inside a lane body use
    /// ``init(blockingContentsOf:_:options:fileID:line:)``, which takes the body's ``BlockingPermit``.
    ///
    /// - Parameters:
    ///   - url: The file to read.
    ///   - options: Foundation's reading options.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `Data(contentsOf:options:)` throws.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public init(blockingContentsOf url: URL, options: Data.ReadingOptions = [], fileID: StaticString = #fileID, line: UInt = #line) throws {
        self = try blockingCall(.fileIO, fileID: fileID, line: line) { try Data(contentsOf: url, options: options) }
    }

    /// Writes the bytes to a file, like `write(to:options:)`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``). Deprecated: inside a lane body use
    /// ``blockingWrite(to:_:options:fileID:line:)``, which takes the body's ``BlockingPermit``.
    ///
    /// - Parameters:
    ///   - url: The file to write.
    ///   - options: Foundation's writing options.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `write(to:options:)` throws.
    @available(*, deprecated, message: "Pass the BlockingPermit of the lane body it runs in: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingWrite(to url: URL, options: Data.WritingOptions = [], fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, fileID: fileID, line: line) { try write(to: url, options: options) }
    }

    /// Reads a file in a lane or allowance body, like `Data(contentsOf:options:)`: the checked blocking call of
    /// ``blockingCall(_:_:fileID:line:_:)``, which compiles only where a ``BlockingPermit`` was given.
    ///
    /// ```swift
    /// let bytes = try await work.run(.userVisible, mayBlock: .files) { permit in try Data(blockingContentsOf: url, permit) }
    /// ```
    ///
    /// - Parameters:
    ///   - url: The file to read.
    ///   - permit: The permit of the body the read runs in.
    ///   - options: Foundation's reading options.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `Data(contentsOf:options:)` throws.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public init(blockingContentsOf url: URL, _ permit: borrowing BlockingPermit, options: Data.ReadingOptions = [],
                fileID: StaticString = #fileID, line: UInt = #line) throws {
        self = try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try Data(contentsOf: url, options: options) }
    }

    /// Writes the bytes to a file in a lane or allowance body, like `write(to:options:)`
    /// (``blockingCall(_:_:fileID:line:_:)``).
    ///
    /// - Parameters:
    ///   - url: The file to write.
    ///   - permit: The permit of the body the write runs in.
    ///   - options: Foundation's writing options.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Throws: What `write(to:options:)` throws.
    @available(*, noasync, message: "Run blocking work in a lane body: work.run(priority, mayBlock: .files) { permit in ... }")
    @inlinable
    public func blockingWrite(to url: URL, _ permit: borrowing BlockingPermit, options: Data.WritingOptions = [],
                              fileID: StaticString = #fileID, line: UInt = #line) throws {
        try blockingCall(.fileIO, permit, fileID: fileID, line: line) { try write(to: url, options: options) }
    }
}
