import CmuxAgentChat
import Foundation

/// Fetches streamed artifacts into a dedicated purgeable caches directory.
actor ChatArtifactTemporaryFileStore {
    private let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let cachesDirectory = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.directory = cachesDirectory.appendingPathComponent(
                "cmux-artifact-previews",
                isDirectory: true
            )
        }
    }

    /// Streams a bounded artifact to disk without accumulating its bytes in memory.
    func fetch(
        path: String,
        expectedSize: Int64,
        modifiedAt: Date? = nil,
        limit: Int64,
        fallbackExtension: String? = nil,
        preferredFilename: String? = nil,
        loader: ChatArtifactLoader,
        progress: @escaping @Sendable (ChatArtifactChunk) async -> Void
    ) async throws -> URL {
        guard expectedSize <= limit else {
            throw ChatArtifactError.tooLarge(limitBytes: limit)
        }
        let originalExtension = URL(fileURLWithPath: path).pathExtension
        let fileExtension = originalExtension.isEmpty
            ? (fallbackExtension ?? "")
            : originalExtension
        let writer = try ChatArtifactTemporaryFileWriter(
            directory: directory,
            fileExtension: fileExtension,
            preferredFilename: preferredFilename
        )
        do {
            try await loader.stream(
                path: path,
                modifiedAt: modifiedAt,
                size: expectedSize
            ) { chunk in
                try Task.checkCancellation()
                try await writer.append(chunk, limit: limit)
                await progress(chunk)
            }
            try Task.checkCancellation()
            return try await writer.finish()
        } catch {
            await writer.discard()
            throw error
        }
    }

    func remove(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
        let parent = fileURL.deletingLastPathComponent()
        if parent != directory,
           parent.deletingLastPathComponent() == directory {
            try? FileManager.default.removeItem(at: parent)
        }
    }
}
