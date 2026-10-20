import CmuxAgentChat
import Foundation

/// Materializes host artifacts as correctly named local files for system actions.
public actor ChatArtifactFileActionStore {
    /// Shared purgeable store used by artifact viewers and gallery rows.
    public static let applicationDefault = ChatArtifactFileActionStore()

    private let temporaryFileStore: ChatArtifactTemporaryFileStore

    /// Creates a file-action store rooted in a purgeable caches directory.
    ///
    /// - Parameter directory: Optional directory override used by tests.
    public init(directory: URL? = nil) {
        let resolvedDirectory: URL
        if let directory {
            resolvedDirectory = directory
        } else {
            let cachesDirectory = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            resolvedDirectory = cachesDirectory.appendingPathComponent(
                "cmux-artifact-actions",
                isDirectory: true
            )
        }
        temporaryFileStore = ChatArtifactTemporaryFileStore(directory: resolvedDirectory)
    }

    /// Stats and streams one file through the shared content cache.
    ///
    /// The returned URL keeps the source basename so system share and document
    /// pickers display the filename the user expects.
    ///
    /// - Parameters:
    ///   - path: Absolute path on the Mac host.
    ///   - loader: Scoped artifact loader authorizing the path.
    /// - Returns: A local, correctly named temporary file.
    public func materialize(
        path: String,
        loader: ChatArtifactLoader
    ) async throws -> URL {
        let stat = try await loader.stat(path: path)
        guard !stat.isDirectory else {
            throw ChatArtifactError.unsupported
        }
        let filename = Self.filename(for: path)
        return try await temporaryFileStore.fetch(
            path: path,
            expectedSize: stat.size,
            modifiedAt: stat.modifiedAt,
            limit: Int64.max,
            preferredFilename: filename,
            loader: loader,
            progress: { _ in }
        )
    }

    /// Removes a file previously returned by ``materialize(path:loader:)``.
    public func remove(_ fileURL: URL) async {
        await temporaryFileStore.remove(fileURL)
    }

    private static func filename(for path: String) -> String {
        let candidate = URL(fileURLWithPath: path).lastPathComponent
        return candidate.isEmpty ? "Artifact" : candidate
    }
}
