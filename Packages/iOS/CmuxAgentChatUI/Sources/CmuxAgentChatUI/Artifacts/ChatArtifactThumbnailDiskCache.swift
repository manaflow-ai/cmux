import CmuxAgentChat
import CryptoKit
import Foundation

/// Purgeable, size-capped on-disk LRU for Mac-hosted artifact thumbnails.
public actor ChatArtifactThumbnailDiskCache {
    private let directory: URL
    private let maxBytes: Int64
    private let fileManager = FileManager()

    /// Creates a disk cache rooted at an injected directory.
    ///
    /// - Parameters:
    ///   - directory: Cache directory, typically inside the app's Caches directory.
    ///   - maxBytes: Maximum aggregate encoded thumbnail size.
    public init(
        directory: URL,
        maxBytes: Int64 = 100 * 1_024 * 1_024
    ) {
        self.directory = directory
        self.maxBytes = max(0, maxBytes)
    }

    /// Creates the production cache in `Caches/<bundle>/artifact-thumbs/`.
    public static func applicationDefault(
        maxBytes: Int64 = 100 * 1_024 * 1_024,
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> ChatArtifactThumbnailDiskCache {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let bundleComponent = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "cmux"
        return ChatArtifactThumbnailDiskCache(
            directory: caches
                .appendingPathComponent(bundleComponent, isDirectory: true)
                .appendingPathComponent("artifact-thumbs", isDirectory: true),
            maxBytes: maxBytes
        )
    }

    /// Derives the SHA-256 filename key for a fully versioned thumbnail.
    ///
    /// Missing modification time or size returns `nil`, intentionally selecting
    /// memory-only caching for legacy hosts whose metadata cannot self-invalidate.
    public static func key(
        scopeKey: String,
        path: String,
        modifiedAt: Date?,
        size: Int64?,
        maxDimension: Int
    ) -> String? {
        guard let modifiedAt, let size else { return nil }
        let raw = "\(scopeKey)#\(path)#\(String(modifiedAt.timeIntervalSince1970.bitPattern, radix: 16))#\(size)#\(maxDimension)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Reads a cached thumbnail and refreshes its LRU access time.
    public func thumbnail(for key: String, accessedAt: Date = Date()) -> ChatArtifactThumbnail? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let thumbnail = try? JSONDecoder().decode(ChatArtifactThumbnail.self, from: data) else {
            return nil
        }
        try? fileManager.setAttributes([.modificationDate: accessedAt], ofItemAtPath: url.path)
        return thumbnail
    }

    /// Stores a thumbnail and evicts least-recently-used files until under the cap.
    public func insert(
        _ thumbnail: ChatArtifactThumbnail,
        for key: String,
        accessedAt: Date = Date()
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(thumbnail)
        let url = fileURL(for: key)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.modificationDate: accessedAt], ofItemAtPath: url.path)
        try enforceSizeCap()
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key, isDirectory: false)
    }

    private func enforceSizeCap() throws {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        var files: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for url in urls {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            total += size
            files.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard total > maxBytes else { return }
        for file in files.sorted(by: { $0.date < $1.date }) where total > maxBytes {
            try fileManager.removeItem(at: file.url)
            total -= file.size
        }
    }
}
