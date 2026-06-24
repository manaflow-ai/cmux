public import Foundation

/// An on-disk copy of the OpenCode SQLite database (`~/.local/share/opencode/opencode.db`)
/// plus its `-wal`/`-shm` sidecars, taken so a reader can open the database
/// `SQLITE_OPEN_READONLY` without contending with the live OpenCode process.
///
/// The value owns the temporary directory it copied into; call ``remove()`` (or
/// rely on the caller's `defer`) to delete that directory once the read is done.
/// Construct one with ``make(prefix:)``, which returns `nil` when the source
/// database does not exist and throws when the copy fails.
public struct OpenCodeDatabaseSnapshot: Sendable {
    /// The copied database file inside the snapshot directory. Open this
    /// `SQLITE_OPEN_READONLY`.
    public let databaseURL: URL
    private let directoryURL: URL

    private init(databaseURL: URL, directoryURL: URL) {
        self.databaseURL = databaseURL
        self.directoryURL = directoryURL
    }

    /// The expanded path of the live OpenCode database that ``make(prefix:)`` copies.
    private static let sourcePath = ("~/.local/share/opencode/opencode.db" as NSString).expandingTildeInPath

    /// Copies the live OpenCode database (and its `-wal`/`-shm` sidecars) into a
    /// freshly created, uniquely named temporary directory.
    ///
    /// - Parameter prefix: A short label prepended to the snapshot directory name
    ///   (followed by a UUID) so concurrent snapshots never collide.
    /// - Returns: A snapshot owning the temporary directory, or `nil` when the
    ///   source database file does not exist.
    /// - Throws: Any filesystem error raised while creating the directory or
    ///   copying the database/sidecars; the partial directory is cleaned up first.
    public static func make(prefix: String) throws -> OpenCodeDatabaseSnapshot? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourcePath) else { return nil }

        let snapshotDir = fileManager.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: snapshotDir, withIntermediateDirectories: true)

        let snapshotDB = snapshotDir.appendingPathComponent("opencode.db")
        do {
            try fileManager.copyItem(atPath: sourcePath, toPath: snapshotDB.path)
        } catch {
            try? fileManager.removeItem(at: snapshotDir)
            throw error
        }

        do {
            for sidecar in ["-wal", "-shm"] {
                let source = sourcePath + sidecar
                let destination = snapshotDB.path + sidecar
                if fileManager.fileExists(atPath: source) {
                    try fileManager.copyItem(atPath: source, toPath: destination)
                }
            }
        } catch {
            try? fileManager.removeItem(at: snapshotDir)
            throw error
        }

        return OpenCodeDatabaseSnapshot(databaseURL: snapshotDB, directoryURL: snapshotDir)
    }

    /// Deletes the temporary directory backing this snapshot. Safe to call more
    /// than once; failures (e.g. an already-removed directory) are ignored.
    public func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
