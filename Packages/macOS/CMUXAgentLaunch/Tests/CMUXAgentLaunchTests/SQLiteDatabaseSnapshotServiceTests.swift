import Darwin
import Foundation
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
}
