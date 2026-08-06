import Darwin
import Foundation
import SQLite3
import Testing
@testable import CMUXAgentLaunch

@Suite("SQLiteDatabaseSnapshotService")
struct SQLiteDatabaseSnapshotServiceTests {
    @Test(
        "Rejects FIFO sources without blocking in SQLite open",
        .timeLimit(.minutes(1))
    )
    func rejectsFIFOSourceWithoutBlocking() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.fifo", isDirectory: false)
        let destination = root.appendingPathComponent("snapshot.db", isDirectory: false)
        try #require(Darwin.mkfifo(source.path, 0o600) == 0)

        #expect(
            throws: SQLiteDatabaseSnapshotError.sqlite(
                "source database is not a regular file"
            )
        ) {
            try SQLiteDatabaseSnapshotService().copyDatabase(
                from: source.path,
                to: destination.path
            )
        }
    }

    @Test("Rejects symlink sources instead of reopening their targets")
    func rejectsSymlinkSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.db", isDirectory: false)
        let sourceLink = root.appendingPathComponent("source-link.db", isDirectory: false)
        let destination = root.appendingPathComponent("snapshot.db", isDirectory: false)
        try makeDatabase(at: source)
        try FileManager.default.createSymbolicLink(at: sourceLink, withDestinationURL: source)

        #expect(
            throws: SQLiteDatabaseSnapshotError.sqlite(
                "cannot open source database"
            )
        ) {
            try SQLiteDatabaseSnapshotService().copyDatabase(
                from: sourceLink.path,
                to: destination.path
            )
        }
    }

    @Test(
        "Rejects a special-file replacement after source validation",
        .timeLimit(.minutes(1))
    )
    func rejectsSpecialFileReplacementAfterValidation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.db", isDirectory: false)
        let replacement = root.appendingPathComponent("replacement.fifo", isDirectory: false)
        let destination = root.appendingPathComponent("snapshot.db", isDirectory: false)
        try makeDatabase(at: source)
        try #require(Darwin.mkfifo(replacement.path, 0o600) == 0)
        let service = SQLiteDatabaseSnapshotService(
            pagesPerStep: 1,
            sourceValidatedObserver: {
                guard Darwin.unlink(source.path) == 0,
                      Darwin.rename(replacement.path, source.path) == 0 else {
                    throw SQLiteDatabaseSnapshotError.sqlite("fixture replacement failed")
                }
            },
            stepObserver: {}
        )

        #expect(
            throws: SQLiteDatabaseSnapshotError.sqlite(
                "source database changed while opening"
            )
        ) {
            try service.copyDatabase(
                from: source.path,
                to: destination.path
            )
        }
    }

    private func makeDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw SQLiteDatabaseSnapshotError.sqlite("fixture open failed")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(
            database,
            "CREATE TABLE records (value TEXT); INSERT INTO records VALUES ('private');",
            nil,
            nil,
            nil
        ) == SQLITE_OK else {
            throw SQLiteDatabaseSnapshotError.sqlite("fixture setup failed")
        }
    }
}
