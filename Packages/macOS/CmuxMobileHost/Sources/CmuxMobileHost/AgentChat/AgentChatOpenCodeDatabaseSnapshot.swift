public import Foundation

/// A consistent read-only copy of OpenCode's SQLite database and its WAL
/// sidecars. OpenCode writes recent rows to `opencode.db-wal`, so copying only
/// the main database can return a stale or incomplete view.
public enum AgentChatOpenCodeDatabaseSnapshot {
    public struct Snapshot: Sendable {
        public let databaseURL: URL
        private let directoryURL: URL

        fileprivate init(databaseURL: URL, directoryURL: URL) {
            self.databaseURL = databaseURL
            self.directoryURL = directoryURL
        }

        public func remove() {
            try? FileManager.default.removeItem(at: directoryURL)
        }
    }

    /// Copies the database and any present `-wal`/`-shm` files into a private
    /// temporary directory. Returns `nil` when the source does not exist.
    public static func make(sourceURL: URL, prefix: String) throws -> Snapshot? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }
        let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let databaseURL = directoryURL.appendingPathComponent("opencode.db", isDirectory: false)
        do {
            try fileManager.copyItem(at: sourceURL, to: databaseURL)
            for sidecar in ["-wal", "-shm"] {
                let source = URL(fileURLWithPath: sourceURL.path + sidecar)
                let destination = URL(fileURLWithPath: databaseURL.path + sidecar)
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.copyItem(at: source, to: destination)
                }
            }
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
        return Snapshot(databaseURL: databaseURL, directoryURL: directoryURL)
    }
}
