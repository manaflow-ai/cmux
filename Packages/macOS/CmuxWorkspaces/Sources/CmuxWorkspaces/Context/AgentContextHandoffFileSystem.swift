import Foundation

/// Reads bounded handoff metadata and contents for context-clear verification.
nonisolated protocol AgentContextHandoffFileSystem: Sendable {
    /// Returns metadata for a path, or `nil` when no path exists.
    /// - Parameter path: The local handoff path to inspect.
    /// - Returns: Typed metadata when the path exists.
    func metadata(for path: URL) async throws -> AgentContextHandoffFileMetadata?

    /// Reads at most the requested number of bytes from a path.
    /// - Parameters:
    ///   - path: The handoff path to read.
    ///   - maximumBytes: The hard read limit enforced by the verifier.
    /// - Returns: The bytes read, which may be shorter than the limit.
    func readData(at path: URL, maximumBytes: Int) async throws -> Data
}
