public import Foundation

/// A file-backed ``TerminalSnapshotPersisting`` that reads and writes a JSON snapshot on disk.
public final class TerminalSnapshotStore: TerminalSnapshotPersisting {
    private let fileURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// Creates a file-backed snapshot store.
    /// - Parameter fileURL: The file to read and write. Defaults to a `terminal-store.json`
    ///   file in the user's Application Support directory.
    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    /// Loads the snapshot from disk, returning an empty snapshot on any read/decode failure.
    public func load() -> TerminalStoreSnapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? decoder.decode(TerminalStoreSnapshot.self, from: data) else {
            return .empty()
        }

        return snapshot
    }

    /// Atomically writes the snapshot to disk, creating the parent directory if needed.
    /// - Parameter snapshot: The snapshot to save.
    /// - Throws: An error if the directory cannot be created or the file cannot be written.
    public func save(_ snapshot: TerminalStoreSnapshot) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func defaultFileURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory
        return baseURL.appendingPathComponent("terminal-store.json")
    }
}
