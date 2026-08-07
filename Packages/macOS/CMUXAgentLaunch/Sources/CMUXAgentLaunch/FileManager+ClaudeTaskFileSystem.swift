import Foundation

extension FileManager: ClaudeTaskFileSystem {
    /// Reads URL resource metadata for Claude task-store validation.
    ///
    /// - Parameters:
    ///   - url: The filesystem item whose metadata should be read.
    ///   - keys: The exact resource properties requested by the loader.
    /// - Returns: The requested URL resource values.
    /// - Throws: A filesystem error when the item cannot be inspected.
    public func resourceValues(
        for url: URL,
        keys: Set<URLResourceKey>
    ) throws -> URLResourceValues {
        try url.resourceValues(forKeys: keys)
    }
}
