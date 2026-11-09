public import Foundation

/// Classic's session as read, the save it came from, and the files to back up.
public nonisolated struct ClassicSnapshotRead: Sendable {
    public var snapshot: ClassicSessionSnapshot
    public var source: ClassicMigrationSource
    public var backups: [URL]

    public init(snapshot: ClassicSessionSnapshot, source: ClassicMigrationSource, backups: [URL]) {
        self.snapshot = snapshot
        self.source = source
        self.backups = backups
    }
}
