/// A filesystem the file tree can browse: this Mac, an SSH host or a Cloud VM.
///
/// Conformers perform I/O off the main actor and must be safe to call
/// concurrently. ``FileTreeEngine`` is the only caller in the app.
///
/// ```swift
/// struct FixtureProvider: FileTreeProvider {
///     func listDirectory(at path: String) async throws -> FileTreeListing {
///         FileTreeListing(entries: [FileTreeEntry(name: "a", path: path + "/a", kind: .file)])
///     }
/// }
/// ```
public protocol FileTreeProvider: Sendable {
    /// Lists one directory, hidden entries included.
    /// - Parameter path: The absolute directory path.
    /// - Returns: The directory's entries in any order.
    /// - Throws: A provider error when the directory cannot be read.
    func listDirectory(at path: String) async throws -> FileTreeListing

    /// Lists several directories, ideally in one round trip.
    ///
    /// Restoring an expanded tree over SSH would otherwise pay one network
    /// round trip per directory. The default implementation lists the paths
    /// one at a time.
    /// - Parameter paths: Absolute directory paths, without duplicates.
    /// - Returns: One result per requested path, keyed by path.
    func listDirectories(at paths: [String]) async -> [String: Result<FileTreeListing, any Error>]

    /// A stream of filesystem change batches under `rootPath`, or `nil` when
    /// the provider cannot observe changes and relies on explicit refreshes.
    /// - Parameter rootPath: The absolute root the tree displays.
    func changes(under rootPath: String) -> AsyncStream<FileTreeChangeBatch>?
}

extension FileTreeProvider {
    /// Lists each path in turn.
    public func listDirectories(at paths: [String]) async -> [String: Result<FileTreeListing, any Error>] {
        var results: [String: Result<FileTreeListing, any Error>] = [:]
        for path in paths {
            if Task.isCancelled { break }
            do {
                results[path] = .success(try await listDirectory(at: path))
            } catch {
                results[path] = .failure(error)
            }
        }
        return results
    }

    /// No change observation by default.
    public func changes(under rootPath: String) -> AsyncStream<FileTreeChangeBatch>? {
        nil
    }
}
