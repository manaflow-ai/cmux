public import Foundation

extension URL {
    /// Reads resource values, like `resourceValues(forKeys:)`, as a checked blocking call
    /// (``assertBlockingAllowed(_:fileID:line:)``): a value the URL has not cached is a file
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
        assertBlockingAllowed(.fileIO, fileID: fileID, line: line)
        return try resourceValues(forKeys: keys)
    }
}
