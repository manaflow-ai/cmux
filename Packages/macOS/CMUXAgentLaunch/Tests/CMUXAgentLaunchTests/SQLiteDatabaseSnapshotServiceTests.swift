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

    @Test("Snapshots databases whose parent directory is read-only")
    func snapshotsDatabaseFromReadOnlyParentDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        defer {
            _ = Darwin.chmod(sourceDirectory.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        let source = sourceDirectory.appendingPathComponent("source.db", isDirectory: false)
        let destination = root.appendingPathComponent("snapshot.db", isDirectory: false)
        try makeDatabase(at: source)
        try #require(Darwin.chmod(sourceDirectory.path, 0o500) == 0)

        try SQLiteDatabaseSnapshotService().copyDatabase(
            from: source.path,
            to: destination.path
        )

        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Rejects a hot rollback journal instead of hiding it from SQLite")
    func rejectsHotRollbackJournal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.db", isDirectory: false)
        let journal = URL(fileURLWithPath: source.path + "-journal", isDirectory: false)
        let destination = root.appendingPathComponent("snapshot.db", isDirectory: false)
        try makeDatabase(at: source)
        var journalData = Data(repeating: 0, count: 1_024)
        journalData.replaceSubrange(
            0..<8,
            with: [0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]
        )
        try journalData.write(to: journal)

        #expect(
            throws: SQLiteDatabaseSnapshotError.sqlite(
                "source database has a hot rollback journal"
            )
        ) {
            try SQLiteDatabaseSnapshotService().copyDatabase(
                from: source.path,
                to: destination.path
            )
        }
    }

    @Test("Counts live WAL bytes toward the aggregate snapshot limit")
    func rejectsLargeWALAboveAggregateLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.db", isDirectory: false)
        let destination = root.appendingPathComponent("snapshot.db", isDirectory: false)
        var database: OpaquePointer?
        try #require(sqlite3_open(source.path, &database) == SQLITE_OK)
        let openedDatabase = try #require(database)
        defer { sqlite3_close(openedDatabase) }
        try #require(sqlite3_exec(
            openedDatabase,
            """
            PRAGMA journal_mode = WAL;
            PRAGMA wal_autocheckpoint = 0;
            CREATE TABLE records (id INTEGER PRIMARY KEY, value BLOB);
            INSERT INTO records VALUES (1, randomblob(4096));
            """,
            nil,
            nil,
            nil
        ) == SQLITE_OK)
        for _ in 0..<64 {
            try #require(sqlite3_exec(
                openedDatabase,
                "UPDATE records SET value = randomblob(4096) WHERE id = 1;",
                nil,
                nil,
                nil
            ) == SQLITE_OK)
        }
        let maximumBytes = 64 * 1_024
        let walSize = try #require(
            FileManager.default.attributesOfItem(atPath: source.path + "-wal")[.size] as? NSNumber
        ).intValue
        #expect(walSize > maximumBytes)

        #expect(
            throws: SQLiteDatabaseSnapshotError.snapshotTooLarge(
                maximumBytes: maximumBytes
            )
        ) {
            try SQLiteDatabaseSnapshotService().copyDatabase(
                from: source.path,
                to: destination.path,
                maximumBytes: maximumBytes
            )
        }
    }

    @Test("Removes every destination artifact after an interrupted backup")
    func removesDestinationArtifactsAfterInterruptedBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.db", isDirectory: false)
        let destination = root.appendingPathComponent("snapshot.db", isDirectory: false)
        try makeDatabase(at: source)
        let interruptedService = SQLiteDatabaseSnapshotService(
            pagesPerStep: 1,
            stepObserver: {
                throw SQLiteDatabaseSnapshotError.sqlite("fixture interruption")
            }
        )

        #expect(
            throws: SQLiteDatabaseSnapshotError.sqlite("fixture interruption")
        ) {
            try interruptedService.copyDatabase(
                from: source.path,
                to: destination.path
            )
        }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            #expect(!FileManager.default.fileExists(atPath: destination.path + suffix))
        }

        try SQLiteDatabaseSnapshotService().copyDatabase(
            from: source.path,
            to: destination.path
        )
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Temporary source bindings carry crash-cleanup leases")
    func temporarySourceBindingsCarryCleanupLeases() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.db", isDirectory: false)
        let destination = root.appendingPathComponent("snapshot.db", isDirectory: false)
        try makeDatabase(at: source)
        var sourceMetadata = stat()
        try #require(Darwin.lstat(source.path, &sourceMetadata) == 0)
        let service = SQLiteDatabaseSnapshotService(
            pagesPerStep: 1,
            stepObserver: {
                let candidates = try FileManager.default.contentsOfDirectory(
                    at: FileManager.default.temporaryDirectory,
                    includingPropertiesForKeys: nil
                )
                let binding = candidates.first { candidate in
                    guard candidate.lastPathComponent.hasPrefix(
                        ".cmux-sqlite-source-"
                    ) || candidate.lastPathComponent.hasPrefix(
                        "cmux-sqlite-source-"
                    ) else {
                        return false
                    }
                    let database = candidate.appendingPathComponent(
                        source.lastPathComponent,
                        isDirectory: false
                    )
                    var metadata = stat()
                    return Darwin.lstat(database.path, &metadata) == 0
                        && metadata.st_dev == sourceMetadata.st_dev
                        && metadata.st_ino == sourceMetadata.st_ino
                }
                guard let binding,
                      FileManager.default.fileExists(
                          atPath: binding.appendingPathComponent(
                              ".cmux-binding-lease",
                              isDirectory: false
                          ).path
                      ) else {
                    throw SQLiteDatabaseSnapshotError.sqlite(
                        "temporary source binding is missing cleanup lease"
                    )
                }
                throw SQLiteDatabaseSnapshotError.sqlite("fixture interruption")
            }
        )

        #expect(
            throws: SQLiteDatabaseSnapshotError.sqlite("fixture interruption")
        ) {
            try service.copyDatabase(from: source.path, to: destination.path)
        }
    }

    @Test("Preserves destination sidecars that predate the snapshot call")
    func preservesPreexistingDestinationSidecars() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        let destinationDirectory = root.appendingPathComponent(
            "private-destination",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.db", isDirectory: false)
        let destination = destinationDirectory.appendingPathComponent(
            "snapshot.db",
            isDirectory: false
        )
        let preexistingWAL = URL(
            fileURLWithPath: destination.path + "-wal",
            isDirectory: false
        )
        let marker = Data("unrelated-sidecar".utf8)
        try makeDatabase(at: source)
        try marker.write(to: preexistingWAL)

        #expect(
            throws: SQLiteDatabaseSnapshotError.sqlite(
                "snapshot destination sidecars already exist"
            )
        ) {
            try SQLiteDatabaseSnapshotService().copyDatabase(
                from: source.path,
                to: destination.path
            )
        }

        #expect(try Data(contentsOf: preexistingWAL) == marker)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Prunes abandoned same-volume bindings and releases their hard links")
    func prunesAbandonedSameVolumeBindings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.db", isDirectory: false)
        let abandonedDirectory = root.appendingPathComponent(
            ".cmux-sqlite-source-\(UUID().uuidString)",
            isDirectory: true
        )
        let abandonedDatabase = abandonedDirectory.appendingPathComponent(
            "source.db",
            isDirectory: false
        )
        let lease = abandonedDirectory.appendingPathComponent(
            ".cmux-binding-lease",
            isDirectory: false
        )
        try makeDatabase(at: source)
        try FileManager.default.createDirectory(
            at: abandonedDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try #require(Darwin.link(source.path, abandonedDatabase.path) == 0)
        try sourceBindingLeaseData(databaseName: source.lastPathComponent)
            .write(to: lease, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o600,
                .modificationDate: Date(timeIntervalSince1970: 1),
            ],
            ofItemAtPath: lease.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: abandonedDirectory.path
        )

        SQLiteDatabaseSnapshotService().removeAbandonedSourceBindingDirectories(
            in: root
        )

        #expect(!FileManager.default.fileExists(atPath: abandonedDirectory.path))
        var sourceMetadata = stat()
        try #require(Darwin.lstat(source.path, &sourceMetadata) == 0)
        #expect(sourceMetadata.st_nlink == 1)
    }

    @Test("A snapshot prunes abandoned temporary source bindings")
    func snapshotPrunesAbandonedTemporaryBinding() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let root = temporaryDirectory.appendingPathComponent(
            "cmux-sqlite-snapshot-\(UUID().uuidString)",
            isDirectory: true
        )
        let abandonedDirectory = temporaryDirectory.appendingPathComponent(
            ".cmux-sqlite-source-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: abandonedDirectory)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: abandonedDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let source = root.appendingPathComponent("source.db", isDirectory: false)
        let destination = root.appendingPathComponent("snapshot.db", isDirectory: false)
        let abandonedDatabase = abandonedDirectory.appendingPathComponent(
            source.lastPathComponent,
            isDirectory: false
        )
        let lease = abandonedDirectory.appendingPathComponent(
            ".cmux-binding-lease",
            isDirectory: false
        )
        try makeDatabase(at: source)
        try #require(Darwin.link(source.path, abandonedDatabase.path) == 0)
        try sourceBindingLeaseData(databaseName: source.lastPathComponent)
            .write(to: lease, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: lease.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: abandonedDirectory.path
        )

        try SQLiteDatabaseSnapshotService().copyDatabase(
            from: source.path,
            to: destination.path
        )

        #expect(!FileManager.default.fileExists(atPath: abandonedDirectory.path))
    }

    @Test("Preserves a same-volume binding while another snapshot holds its lease")
    func preservesLeasedSameVolumeBinding() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let activeDirectory = root.appendingPathComponent(
            ".cmux-sqlite-source-\(UUID().uuidString)",
            isDirectory: true
        )
        let lease = activeDirectory.appendingPathComponent(
            ".cmux-binding-lease",
            isDirectory: false
        )
        let database = activeDirectory.appendingPathComponent(
            "source.db",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: activeDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try sourceBindingLeaseData(databaseName: database.lastPathComponent)
            .write(to: lease, options: .withoutOverwriting)
        try Data("sqlite fixture".utf8).write(
            to: database,
            options: .withoutOverwriting
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: lease.path
        )
        let leaseDescriptor = Darwin.open(
            lease.path,
            O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK
        )
        try #require(leaseDescriptor >= 0)
        defer { _ = Darwin.close(leaseDescriptor) }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: activeDirectory.path
        )

        SQLiteDatabaseSnapshotService().removeAbandonedSourceBindingDirectories(
            in: root
        )

        #expect(FileManager.default.fileExists(atPath: activeDirectory.path))
        #expect(FileManager.default.fileExists(atPath: lease.path))
        #expect(FileManager.default.fileExists(atPath: database.path))
    }

    @Test("Preserves lookalike source binding directories")
    func preservesLookalikeSourceBindingDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lookalikeDirectory = root.appendingPathComponent(
            ".cmux-sqlite-source-user-data",
            isDirectory: true
        )
        let lease = lookalikeDirectory.appendingPathComponent(
            ".cmux-binding-lease",
            isDirectory: false
        )
        let marker = lookalikeDirectory.appendingPathComponent(
            "keep-me.txt",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: lookalikeDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try sourceBindingLeaseData(databaseName: "source.db")
            .write(to: lease, options: .withoutOverwriting)
        try Data("user data".utf8).write(to: marker, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o600,
                .modificationDate: Date(timeIntervalSince1970: 1),
            ],
            ofItemAtPath: lease.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: lookalikeDirectory.path
        )

        SQLiteDatabaseSnapshotService().removeAbandonedSourceBindingDirectories(
            in: root
        )

        #expect(FileManager.default.fileExists(atPath: lookalikeDirectory.path))
        #expect(try Data(contentsOf: marker) == Data("user data".utf8))
    }

    @Test("Preserves unexpected files in abandoned source bindings")
    func preservesUnexpectedFilesInAbandonedSourceBindings() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-sqlite-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bindingDirectory = root.appendingPathComponent(
            ".cmux-sqlite-source-\(UUID().uuidString)",
            isDirectory: true
        )
        let lease = bindingDirectory.appendingPathComponent(
            ".cmux-binding-lease",
            isDirectory: false
        )
        let marker = bindingDirectory.appendingPathComponent(
            "keep-me.txt",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: bindingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try sourceBindingLeaseData(databaseName: "source.db")
            .write(to: lease, options: .withoutOverwriting)
        try Data("user data".utf8).write(to: marker, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [
                .posixPermissions: 0o600,
                .modificationDate: Date(timeIntervalSince1970: 1),
            ],
            ofItemAtPath: lease.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: bindingDirectory.path
        )

        SQLiteDatabaseSnapshotService().removeAbandonedSourceBindingDirectories(
            in: root
        )

        #expect(FileManager.default.fileExists(atPath: bindingDirectory.path))
        #expect(try Data(contentsOf: marker) == Data("user data".utf8))
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

    private func sourceBindingLeaseData(databaseName: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "databaseName": databaseName,
                "version": 1,
            ],
            options: [.sortedKeys]
        )
    }
}
