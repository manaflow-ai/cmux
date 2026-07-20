import CmuxAgentChat
import CryptoKit
import Foundation

/// Memory-fronted, purgeable disk LRU for fully fetched artifact bytes.
public actor ChatArtifactContentCache {
    private let directory: URL
    private let maxDiskBytes: Int64
    private let maxMemoryBytes: Int
    private let fileManager = FileManager()
    private let memoryCache = NSCache<NSString, NSData>()

    /// Creates a content cache rooted at an injected directory.
    ///
    /// - Parameters:
    ///   - directory: Purgeable cache directory.
    ///   - maxDiskBytes: Maximum aggregate disk usage.
    ///   - maxMemoryBytes: Approximate `NSCache` byte-cost limit.
    public init(
        directory: URL,
        maxDiskBytes: Int64 = 256 * 1_024 * 1_024,
        maxMemoryBytes: Int = 32 * 1_024 * 1_024
    ) {
        self.directory = directory
        self.maxDiskBytes = max(0, maxDiskBytes)
        self.maxMemoryBytes = max(0, maxMemoryBytes)
        memoryCache.totalCostLimit = self.maxMemoryBytes
    }

    /// Creates the production cache in `Caches/<bundle>/artifact-content/`.
    ///
    /// - Parameters:
    ///   - maxDiskBytes: Maximum aggregate disk usage.
    ///   - maxMemoryBytes: Approximate `NSCache` byte-cost limit.
    ///   - fileManager: Filesystem locator used to resolve the caches directory.
    ///   - bundleIdentifier: Bundle-specific directory component.
    /// - Returns: A cache configured for application use.
    public static func applicationDefault(
        maxDiskBytes: Int64 = 256 * 1_024 * 1_024,
        maxMemoryBytes: Int = 32 * 1_024 * 1_024,
        fileManager: FileManager = .default,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> ChatArtifactContentCache {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let bundleComponent = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? "cmux"
        return ChatArtifactContentCache(
            directory: caches
                .appendingPathComponent(bundleComponent, isDirectory: true)
                .appendingPathComponent("artifact-content", isDirectory: true),
            maxDiskBytes: maxDiskBytes,
            maxMemoryBytes: maxMemoryBytes
        )
    }

    /// Derives a versioned key from authorization scope and host file metadata.
    public static func key(
        scopeKey: String,
        path: String,
        modifiedAt: Date?,
        size: Int64?
    ) -> String? {
        guard let modifiedAt, let size else { return nil }
        let raw = "\(scopeKey)#\(path)#\(String(modifiedAt.timeIntervalSince1970.bitPattern, radix: 16))#\(size)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Replays a cache hit or writes a fetched stream through atomically.
    ///
    /// - Returns: `true` when no source fetch was needed.
    func stream(
        for key: String,
        expectedSize: Int64,
        accessedAt: Date = Date(),
        fetch: @escaping @Sendable (
            _ receive: @Sendable (ChatArtifactChunk) async throws -> Void
        ) async throws -> Void,
        receive: @escaping @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws -> Bool {
        if let data = memoryCache.object(forKey: key as NSString) {
            let value = Data(referencing: data)
            try? touch(fileURL(for: key), at: accessedAt)
            try await receive(Self.chunk(data: value, totalSize: expectedSize))
            return true
        }

        if try await replayDiskEntry(
            for: key,
            expectedSize: expectedSize,
            accessedAt: accessedAt,
            receive: receive
        ) {
            return true
        }

        let writer = try ChatArtifactContentCacheWriter(
            directory: directory,
            key: key,
            expectedSize: expectedSize,
            retainsMemoryCopy: expectedSize <= Int64(maxMemoryBytes)
        )
        do {
            try await fetch { chunk in
                try Task.checkCancellation()
                try await writer.append(chunk)
                try await receive(chunk)
            }
            try Task.checkCancellation()
            let data = try await writer.finish()
            if let data, maxMemoryBytes > 0 {
                memoryCache.setObject(data as NSData, forKey: key as NSString, cost: data.count)
            }
            try touch(fileURL(for: key), at: accessedAt)
            try enforceDiskBudget()
            return false
        } catch {
            await writer.discard()
            throw error
        }
    }

    private func replayDiskEntry(
        for key: String,
        expectedSize: Int64,
        accessedAt: Date,
        receive: @escaping @Sendable (ChatArtifactChunk) async throws -> Void
    ) async throws -> Bool {
        let url = fileURL(for: key)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == expectedSize else {
            try? fileManager.removeItem(at: url)
            return false
        }
        try touch(url, at: accessedAt)
        if expectedSize == 0 {
            try await receive(Self.chunk(data: Data(), totalSize: 0))
            return true
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while offset < expectedSize {
            try Task.checkCancellation()
            let requested = Int(min(Int64(Self.diskReadChunkBytes), expectedSize - offset))
            guard let data = try handle.read(upToCount: requested), !data.isEmpty else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let chunkOffset = offset
            offset += Int64(data.count)
            try await receive(ChatArtifactChunk(
                data: data,
                offset: chunkOffset,
                totalSize: expectedSize,
                eof: offset == expectedSize
            ))
        }
        return true
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key, isDirectory: false)
    }

    private func touch(_ url: URL, at date: Date) throws {
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func enforceDiskBudget() throws {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey,
            .contentModificationDateKey,
            .isRegularFileKey,
            .nameKey,
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        var entries: [(url: URL, size: Int64, accessedAt: Date)] = []
        var totalBytes: Int64 = 0
        for url in urls {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true,
                  values.name?.hasSuffix(".partial") != true else { continue }
            let size = Int64(values.fileSize ?? 0)
            totalBytes += size
            entries.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard totalBytes > maxDiskBytes else { return }
        for entry in entries.sorted(by: { $0.accessedAt < $1.accessedAt })
        where totalBytes > maxDiskBytes {
            try fileManager.removeItem(at: entry.url)
            totalBytes -= entry.size
        }
    }

    private static func chunk(data: Data, totalSize: Int64) -> ChatArtifactChunk {
        ChatArtifactChunk(data: data, offset: 0, totalSize: totalSize, eof: true)
    }

    private static let diskReadChunkBytes = 1 * 1_024 * 1_024
}
