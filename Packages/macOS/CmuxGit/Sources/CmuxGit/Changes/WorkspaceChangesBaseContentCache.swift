import Foundation

/// Materializes base-revision blobs once and serves them from an actor-owned LRU cache.
actor WorkspaceChangesBaseContentCache {
    enum Error: Swift.Error, Equatable {
        case entryExceedsByteBudget
    }

    static let defaultByteBudget: Int64 = 256 * 1024 * 1024
    static let defaultMaximumEntryCount = 256

    struct Key: Hashable, Sendable {
        let repoRoot: String
        let baseCommitOID: String
        let path: String
    }

    private struct Entry: Sendable {
        let fileURL: URL
        let size: Int64
        let accessOrdinal: UInt64
    }

    private let byteBudget: Int64
    private let maximumEntryCount: Int
    // FileManager is documented thread-safe; deinit begins after actor access ends and removes only this cache's unique directory.
    private nonisolated(unsafe) let fileManager: FileManager
    private let directory: URL
    private var entries: [Key: Entry] = [:]
    private var totalBytes: Int64 = 0
    private var nextAccessOrdinal: UInt64 = 0

    init(
        byteBudget: Int64 = WorkspaceChangesBaseContentCache.defaultByteBudget,
        maximumEntryCount: Int = WorkspaceChangesBaseContentCache.defaultMaximumEntryCount,
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil
    ) {
        self.byteBudget = max(0, byteBudget)
        self.maximumEntryCount = max(1, maximumEntryCount)
        self.fileManager = fileManager
        directory = (temporaryDirectory ?? fileManager.temporaryDirectory)
            .appendingPathComponent("cmux-workspace-changes-base-\(UUID().uuidString)", isDirectory: true)
    }

    deinit {
        try? fileManager.removeItem(at: directory)
    }

    func permitsEntry(size: Int64) -> Bool {
        size >= 0 && size <= byteBudget
    }

    func fileURL(
        for key: Key,
        materialize: @Sendable (_ destination: URL) throws -> Int64
    ) throws -> URL {
        if let entry = entries[key] {
            if fileManager.fileExists(atPath: entry.fileURL.path) {
                nextAccessOrdinal &+= 1
                entries[key] = Entry(
                    fileURL: entry.fileURL,
                    size: entry.size,
                    accessOrdinal: nextAccessOrdinal
                )
                return entry.fileURL
            }
            entries[key] = nil
            totalBytes -= entry.size
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let pathExtension = URL(fileURLWithPath: key.path).pathExtension
        let filename = pathExtension.isEmpty
            ? UUID().uuidString
            : "\(UUID().uuidString).\(pathExtension)"
        let destination = directory.appendingPathComponent(filename, isDirectory: false)
        do {
            let size = try materialize(destination)
            guard permitsEntry(size: size) else {
                throw Error.entryExceedsByteBudget
            }
            nextAccessOrdinal &+= 1
            entries[key] = Entry(
                fileURL: destination,
                size: size,
                accessOrdinal: nextAccessOrdinal
            )
            totalBytes += size
            evictIfNeeded()
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    private func evictIfNeeded() {
        // The count bound keeps zero-byte blobs (invisible to the byte
        // budget) from growing entries and temp files without limit.
        while totalBytes > byteBudget || entries.count > maximumEntryCount,
              let victim = entries
                .min(by: { $0.value.accessOrdinal < $1.value.accessOrdinal }) {
            entries[victim.key] = nil
            totalBytes -= victim.value.size
            try? fileManager.removeItem(at: victim.value.fileURL)
        }
    }
}
