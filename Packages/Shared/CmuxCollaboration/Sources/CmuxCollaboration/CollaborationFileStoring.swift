public import Foundation

/// Filesystem operations used by collaboration disk reconciliation.
public protocol CollaborationFileStoring: Sendable {
    /// Reads a UTF-8 text file.
    /// - Parameter url: The file URL to read.
    /// - Returns: The file contents.
    func readText(at url: URL) async throws -> String

    /// Writes a UTF-8 text file atomically.
    /// - Parameters:
    ///   - text: The text to write.
    ///   - url: The destination file URL.
    func writeText(_ text: String, to url: URL) async throws

    /// Returns whether a file exists.
    /// - Parameter url: The file URL to check.
    /// - Returns: Whether the file exists.
    func fileExists(at url: URL) async -> Bool
}
