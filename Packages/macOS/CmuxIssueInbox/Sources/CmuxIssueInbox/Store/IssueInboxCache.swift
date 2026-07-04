public import Foundation

/// Reads and writes the Issue Inbox disk cache.
public struct IssueInboxCache {
    /// Default cache directory relative to the user's home directory.
    public static let relativeDirectoryPath = "Library/Application Support/cmux/issue-inbox"

    private let directoryURL: URL

    /// Cache file URL.
    public var fileURL: URL {
        directoryURL.appendingPathComponent("cache.json", isDirectory: false)
    }

    /// Creates a disk cache.
    ///
    /// - Parameter directoryURL: Directory containing `cache.json`.
    public init(
        directoryURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(Self.relativeDirectoryPath, isDirectory: true)
    ) {
        self.directoryURL = directoryURL
    }

    /// Reads the current cache snapshot.
    ///
    /// - Returns: Cached snapshot, or an empty snapshot if the cache is absent.
    /// - Throws: JSON decoding or file read errors.
    public func read() throws -> IssueInboxCacheSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return IssueInboxCacheSnapshot()
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IssueInboxCacheSnapshot.self, from: data)
    }

    /// Atomically writes a cache snapshot to disk.
    ///
    /// - Parameter snapshot: Snapshot to persist.
    /// - Throws: File or JSON encoding errors.
    public func write(_ snapshot: IssueInboxCacheSnapshot) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}
