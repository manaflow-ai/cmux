public import Foundation

extension URL {
    /// Reads resource values, like `resourceValues(forKeys:)`, as a checked blocking call
    /// (``blockingCall(_:fileID:line:_:)``): a value the URL has not cached is a file
    /// system read.
    ///
    /// - Parameters:
    ///   - keys: The values to read.
    ///   - fileID: The calling code's `#fileID` (names the call site).
    ///   - line: The calling code's `#line`.
    /// - Returns: The values.
    /// - Throws: What `resourceValues(forKeys:)` throws.
    @inlinable
    public func blockingResourceValues(forKeys keys: Set<URLResourceKey>, fileID: StaticString = #fileID,
                                       line: UInt = #line) throws -> URLResourceValues {
        return try blockingCall(.fileIO, fileID: fileID, line: line) { try resourceValues(forKeys: keys) }
    }
}
