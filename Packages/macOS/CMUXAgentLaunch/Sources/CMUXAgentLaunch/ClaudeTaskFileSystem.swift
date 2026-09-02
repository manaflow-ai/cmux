import Foundation

/// The bounded directory operations needed to resolve Claude task snapshots.
public protocol ClaudeTaskFileSystem {
    /// Reports whether a path exists and whether it is a directory.
    ///
    /// - Parameters:
    ///   - path: The filesystem path to inspect.
    ///   - isDirectory: An optional destination for the directory result.
    /// - Returns: `true` when an item exists at `path`.
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool

    /// Creates a shallow URL directory enumerator for a bounded scan.
    ///
    /// - Parameters:
    ///   - url: The root directory to enumerate.
    ///   - keys: Resource keys to prefetch for each entry.
    ///   - mask: Options controlling enumeration depth and filtering.
    ///   - handler: The callback used to classify enumeration errors.
    /// - Returns: A directory enumerator, or `nil` when enumeration cannot start.
    func enumerator(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions,
        errorHandler handler: ((URL, any Error) -> Bool)?
    ) -> FileManager.DirectoryEnumerator?

    /// Reads resource metadata through the injectable filesystem boundary.
    ///
    /// - Parameters:
    ///   - url: The filesystem item whose metadata should be read.
    ///   - keys: The exact resource properties needed by the loader.
    /// - Returns: The requested resource values.
    /// - Throws: A filesystem error when the item cannot be inspected.
    func resourceValues(
        for url: URL,
        keys: Set<URLResourceKey>
    ) throws -> URLResourceValues
}
