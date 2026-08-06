import Darwin
import Foundation
import SQLite3

private let sqliteSourceBindingDirectoryPrefix = ".cmux-sqlite-source"
private let sqliteSourceBindingLeaseName = ".cmux-binding-lease"
private let sqliteSourceBindingLeaseVersion = 1
private let sqliteSourceBindingLeaseMaximumBytes: off_t = 4 * 1_024
private let sqliteAbandonedSourceBindingGraceInterval: TimeInterval = 60

/// Copies a live SQLite database through SQLite's online backup API.
///
/// The resulting file represents one consistent source transaction and does not
/// depend on separately copied WAL or shared-memory sidecars.
///
/// ```swift
/// try SQLiteDatabaseSnapshotService().copyDatabase(
///     from: liveDatabasePath,
///     to: snapshotPath,
///     maximumBytes: 128 * 1_024 * 1_024
/// )
/// ```
public struct SQLiteDatabaseSnapshotService {
    private let fileManager: FileManager
    private let pagesPerStep: Int32
    private let maximumDuration: Duration
    private let now: () -> ContinuousClock.Instant
    private let sourceValidatedObserver: (() throws -> Void)?
    private let stepObserver: (() throws -> Void)?

    /// Creates a database snapshot service.
    /// - Parameters:
    ///   - fileManager: Filesystem dependency used to remove temporary sidecars.
    ///   - maximumDuration: Total backup duration before failing. The ten-second
    ///     default prevents a live writer from starving an incremental backup.
    ///   - now: Monotonic clock read used to enforce `maximumDuration`.
    public init(
        fileManager: FileManager = .default,
        maximumDuration: Duration = .seconds(10),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }
    ) {
        self.fileManager = fileManager
        pagesPerStep = 64
        self.maximumDuration = maximumDuration
        self.now = now
        sourceValidatedObserver = nil
        stepObserver = nil
    }

    init(
        fileManager: FileManager = .default,
        pagesPerStep: Int32,
        maximumDuration: Duration = .seconds(10),
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now },
        sourceValidatedObserver: (() throws -> Void)? = nil,
        stepObserver: @escaping () throws -> Void
    ) {
        self.fileManager = fileManager
        self.pagesPerStep = max(1, pagesPerStep)
        self.maximumDuration = maximumDuration
        self.now = now
        self.sourceValidatedObserver = sourceValidatedObserver
        self.stepObserver = stepObserver
    }

    /// Creates an unpredictable temporary directory that is inaccessible to
    /// other local accounts from the instant it appears.
    public func createPrivateTemporaryDirectory(prefix: String) throws -> URL {
        try createPrivateDirectory(
            in: fileManager.temporaryDirectory,
            prefix: prefix
        )
    }

    /// Copies one consistent transaction from a live SQLite database.
    /// - Parameters:
    ///   - sourcePath: Path to the live source database.
    ///   - destinationPath: Path where the standalone snapshot is created.
    ///   - maximumBytes: Optional upper bound for the logical database image
    ///     plus bound WAL, SHM, and rollback-journal sidecars.
    /// - Throws: ``SQLiteDatabaseSnapshotError`` or ``CancellationError`` when
    ///   the snapshot cannot complete.
    public func copyDatabase(
        from sourcePath: String,
        to destinationPath: String,
        maximumBytes: Int? = nil
    ) throws {
        if let maximumBytes, maximumBytes < 0 {
            throw SQLiteDatabaseSnapshotError.snapshotTooLarge(
                maximumBytes: maximumBytes
            )
        }
        try Task.checkCancellation()
        let startedAt = now()
        try checkDeadline(startedAt: startedAt)
        try validateSnapshotDestination(path: destinationPath)
        let boundSource = try bindSourceDatabase(
            path: sourcePath,
            maximumBytes: maximumBytes
        )
        defer {
            try? fileManager.removeItem(at: boundSource.directoryURL)
            if let leaseDescriptor = boundSource.leaseDescriptor {
                _ = Darwin.close(leaseDescriptor)
            }
        }
        try enforceMaximumSidecarBytes(
            databasePath: boundSource.databaseURL.path,
            maximumBytes: maximumBytes
        )

        var sourceDatabase: OpaquePointer?
        let sourceOpenResult = sqlite3_open_v2(
            boundSource.databaseURL.path,
            &sourceDatabase,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard sourceOpenResult == SQLITE_OK, let sourceDatabase else {
            let message = sqliteMessage(sourceDatabase, fallback: "cannot open source database")
            if let sourceDatabase {
                _ = sqlite3_close(sourceDatabase)
            }
            throw SQLiteDatabaseSnapshotError.sqlite("cannot open source database: \(message)")
        }
        defer { _ = sqlite3_close(sourceDatabase) }

        let pageSize = try databasePageSize(sourceDatabase)
        try checkDeadline(startedAt: startedAt)
        try createPrivateDestinationFile(path: destinationPath)
        var destinationCompleted = false
        defer {
            if !destinationCompleted {
                removeSnapshotArtifacts(destinationPath: destinationPath)
            }
        }
        var destinationDatabase: OpaquePointer?
        let destinationOpenResult = sqlite3_open_v2(
            destinationPath,
            &destinationDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard destinationOpenResult == SQLITE_OK, let destinationDatabase else {
            let message = sqliteMessage(
                destinationDatabase,
                fallback: "cannot open snapshot database"
            )
            if let destinationDatabase {
                _ = sqlite3_close(destinationDatabase)
            }
            throw SQLiteDatabaseSnapshotError.sqlite("cannot open snapshot database: \(message)")
        }
        var destinationDatabaseNeedsClose: OpaquePointer? = destinationDatabase
        defer {
            if let destinationDatabaseNeedsClose {
                _ = sqlite3_close(destinationDatabaseNeedsClose)
            }
        }

        guard let initializedBackup = sqlite3_backup_init(
            destinationDatabase,
            "main",
            sourceDatabase,
            "main"
        ) else {
            throw SQLiteDatabaseSnapshotError.sqlite(
                sqliteMessage(destinationDatabase, fallback: "cannot initialize backup")
            )
        }
        var backup: OpaquePointer? = initializedBackup
        defer {
            if let unfinishedBackup = backup {
                _ = sqlite3_backup_finish(unfinishedBackup)
            }
        }

        var busyRetryCount = 0
        while true {
            try Task.checkCancellation()
            try checkDeadline(startedAt: startedAt)
            guard let activeBackup = backup else {
                throw SQLiteDatabaseSnapshotError.sqlite("backup state became unavailable")
            }
            let stepResult = sqlite3_backup_step(activeBackup, pagesPerStep)
            try enforceMaximumBytes(
                backup: activeBackup,
                pageSize: pageSize,
                maximumBytes: maximumBytes,
                sourceDatabasePath: boundSource.databaseURL.path
            )
            if stepResult != SQLITE_DONE {
                try checkDeadline(startedAt: startedAt)
            }

            switch stepResult {
            case SQLITE_DONE:
                let finishResult = sqlite3_backup_finish(activeBackup)
                backup = nil
                guard finishResult == SQLITE_OK else {
                    throw SQLiteDatabaseSnapshotError.sqlite(
                        "cannot finish backup: \(sqliteMessage(destinationDatabase, fallback: sqliteErrorString(finishResult)))"
                    )
                }
                try makeSnapshotStandalone(destinationDatabase)
                try Task.checkCancellation()
                let closeResult = sqlite3_close(destinationDatabase)
                guard closeResult == SQLITE_OK else {
                    throw SQLiteDatabaseSnapshotError.sqlite(
                        sqliteMessage(destinationDatabase, fallback: "cannot close snapshot database")
                    )
                }
                destinationDatabaseNeedsClose = nil
                try restrictSnapshotArtifactPermissions(destinationPath: destinationPath)
                try removeSnapshotSidecars(destinationPath: destinationPath)
                destinationCompleted = true
                return
            case SQLITE_OK:
                busyRetryCount = 0
                try stepObserver?()
            case SQLITE_BUSY, SQLITE_LOCKED:
                busyRetryCount += 1
                guard busyRetryCount <= 100 else {
                    throw SQLiteDatabaseSnapshotError.sqlite(
                        sqliteMessage(destinationDatabase, fallback: "source database remained busy")
                    )
                }
                try Task.checkCancellation()
                _ = sqlite3_sleep(10)
            default:
                throw SQLiteDatabaseSnapshotError.sqlite(
                    "backup step failed (\(sqliteErrorString(stepResult))): "
                        + "source=\(sqlite3_extended_errcode(sourceDatabase)) "
                        + "destination=\(sqlite3_extended_errcode(destinationDatabase)) "
                        + sqliteMessage(sourceDatabase, fallback: "source unavailable")
                )
            }
        }
    }

    private func checkDeadline(startedAt: ContinuousClock.Instant) throws {
        guard startedAt.duration(to: now()) < maximumDuration else {
            throw SQLiteDatabaseSnapshotError.timedOut(
                maximumDuration: maximumDuration
            )
        }
    }

    /// Binds the validated database inode and its current sidecars to
    /// unpredictable names in a private directory controlled by cmux.
    /// SQLite opens only those hard links, so replacing the caller's path after
    /// validation cannot redirect or block its path-based open.
    private func bindSourceDatabase(
        path: String,
        maximumBytes: Int?
    ) throws -> (
        databaseURL: URL,
        directoryURL: URL,
        leaseDescriptor: Int32?
    ) {
        let sourceURL = URL(fileURLWithPath: path).standardizedFileURL
        guard !sourceURL.lastPathComponent.isEmpty else {
            throw SQLiteDatabaseSnapshotError.sqlite("cannot open source database")
        }
        let sourceDescriptor = try validatedRegularSourceDescriptor(path: sourceURL.path)
        defer { _ = Darwin.close(sourceDescriptor) }
        try sourceValidatedObserver?()
        try rejectHotRollbackJournal(path: sourceURL.path + "-journal")

        let binding = try createPrivateSourceBindingDirectory(
            sourceURL: sourceURL,
            sourceDescriptor: sourceDescriptor
        )
        let directoryURL = binding.directoryURL
        do {
            if binding.requiresCopy {
                try enforceReadOnlySourceCopyMaximumBytes(
                    sourcePath: sourceURL.path,
                    sourceDescriptor: sourceDescriptor,
                    maximumBytes: maximumBytes
                )
            }
            let databaseURL = directoryURL.appendingPathComponent(
                sourceURL.lastPathComponent,
                isDirectory: false
            )
            if binding.requiresCopy {
                try copyValidatedReadOnlyFile(
                    from: sourceURL.path,
                    descriptor: sourceDescriptor,
                    to: databaseURL.path,
                    label: "source database"
                )
            } else {
                try linkValidatedFile(
                    from: sourceURL.path,
                    descriptor: sourceDescriptor,
                    to: databaseURL.path,
                    label: "source database"
                )
            }
            for suffix in ["-wal", "-shm", "-journal"] {
                if binding.requiresCopy {
                    try copyOptionalReadOnlyFile(
                        from: sourceURL.path + suffix,
                        to: databaseURL.path + suffix
                    )
                } else {
                    try linkOptionalRegularFile(
                        from: sourceURL.path + suffix,
                        to: databaseURL.path + suffix
                    )
                }
            }
            try rejectHotRollbackJournal(path: databaseURL.path + "-journal")
            try rejectHotRollbackJournal(path: sourceURL.path + "-journal")
            return (databaseURL, directoryURL, binding.leaseDescriptor)
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            if let leaseDescriptor = binding.leaseDescriptor {
                _ = Darwin.close(leaseDescriptor)
            }
            throw error
        }
    }

    /// Hard links keep SQLite attached to the validated inode. Prefer cmux's
    /// private temporary directory, then a private directory on the source
    /// volume. A cross-volume read-only source is immutable, so copying its
    /// validated files is the only safe fallback that does not write beside it.
    private func createPrivateSourceBindingDirectory(
        sourceURL: URL,
        sourceDescriptor: Int32
    ) throws -> (
        directoryURL: URL,
        requiresCopy: Bool,
        leaseDescriptor: Int32?
    ) {
        var sourceMetadata = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceMetadata) == 0 else {
            throw SQLiteDatabaseSnapshotError.sqlite("cannot inspect source database")
        }

        let temporaryDirectory = try createPrivateTemporaryDirectory(
            prefix: "cmux-sqlite-source"
        )
        var temporaryMetadata = stat()
        guard Darwin.lstat(temporaryDirectory.path, &temporaryMetadata) == 0 else {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw SQLiteDatabaseSnapshotError.sqlite(
                "cannot inspect private snapshot directory"
            )
        }
        if temporaryMetadata.st_dev == sourceMetadata.st_dev {
            return (temporaryDirectory, false, nil)
        }

        var candidateParent = sourceURL.deletingLastPathComponent()
        while true {
            var parentMetadata = stat()
            guard Darwin.lstat(candidateParent.path, &parentMetadata) == 0,
                  parentMetadata.st_dev == sourceMetadata.st_dev else {
                break
            }
            removeAbandonedSourceBindingDirectories(in: candidateParent)
            if let directory = try? createPrivateDirectory(
                in: candidateParent,
                prefix: sqliteSourceBindingDirectoryPrefix
            ) {
                var directoryMetadata = stat()
                if Darwin.lstat(directory.path, &directoryMetadata) == 0,
                   directoryMetadata.st_dev == sourceMetadata.st_dev,
                   directoryMetadata.st_mode & S_IFMT == S_IFDIR,
                   let leaseDescriptor = createSourceBindingLease(
                       in: directory,
                       databaseName: sourceURL.lastPathComponent
                   ) {
                    try? fileManager.removeItem(at: temporaryDirectory)
                    return (directory, false, leaseDescriptor)
                }
                try? fileManager.removeItem(at: directory)
            }
            let nextParent = candidateParent.deletingLastPathComponent()
            if nextParent.path == candidateParent.path { break }
            candidateParent = nextParent
        }

        guard fileSystemIsReadOnly(at: sourceURL.path) else {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw SQLiteDatabaseSnapshotError.sqlite(
                "cannot create same-volume source binding"
            )
        }
        return (temporaryDirectory, true, nil)
    }

    private func createSourceBindingLease(
        in directoryURL: URL,
        databaseName: String
    ) -> Int32? {
        guard sqliteSourceBindingDatabaseNameIsValid(databaseName),
              let contents = try? JSONSerialization.data(
                  withJSONObject: [
                      "databaseName": databaseName,
                      "version": sqliteSourceBindingLeaseVersion,
                  ],
                  options: [.sortedKeys]
              ),
              off_t(contents.count) <= sqliteSourceBindingLeaseMaximumBytes else {
            return nil
        }
        let leaseURL = directoryURL.appendingPathComponent(
            sqliteSourceBindingLeaseName,
            isDirectory: false
        )
        let descriptor = Darwin.open(
            leaseURL.path,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }
        var offset = 0
        while offset < contents.count {
            let written = contents.withUnsafeBytes { bytes in
                Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    contents.count - offset
                )
            }
            guard written > 0 else {
                _ = Darwin.close(descriptor)
                _ = Darwin.unlink(leaseURL.path)
                return nil
            }
            offset += written
        }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              Darwin.fsync(descriptor) == 0 else {
            _ = Darwin.close(descriptor)
            _ = Darwin.unlink(leaseURL.path)
            return nil
        }
        return descriptor
    }

    /// Removes owner-private source bindings left behind by a killed process.
    /// A short age gate closes the create-before-lock race, while the lease
    /// prevents concurrent snapshot processes from deleting live bindings.
    func removeAbandonedSourceBindingDirectories(in parentURL: URL) {
        guard let candidates = try? fileManager.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        let oldestRemovableModificationTime = Date().timeIntervalSince1970
            - sqliteAbandonedSourceBindingGraceInterval

        for candidate in candidates where sqliteSourceBindingDirectoryNameIsGenerated(
            candidate.lastPathComponent
        ) {
            var originalDirectoryMetadata = stat()
            guard Darwin.lstat(candidate.path, &originalDirectoryMetadata) == 0,
                  originalDirectoryMetadata.st_mode & S_IFMT == S_IFDIR,
                  originalDirectoryMetadata.st_uid == Darwin.geteuid(),
                  originalDirectoryMetadata.st_mode & (S_IRWXG | S_IRWXO) == 0,
                  TimeInterval(originalDirectoryMetadata.st_mtimespec.tv_sec)
                    <= oldestRemovableModificationTime else {
                continue
            }

            let leaseURL = candidate.appendingPathComponent(
                sqliteSourceBindingLeaseName,
                isDirectory: false
            )
            let leaseDescriptor = Darwin.open(
                leaseURL.path,
                O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK
            )
            guard leaseDescriptor >= 0 else {
                if errno == ENOENT {
                    _ = Darwin.rmdir(candidate.path)
                }
                continue
            }

            var leaseMetadata = stat()
            let leaseIsPrivate = Darwin.fstat(leaseDescriptor, &leaseMetadata) == 0
                && leaseMetadata.st_mode & S_IFMT == S_IFREG
                && leaseMetadata.st_uid == Darwin.geteuid()
                && leaseMetadata.st_mode & (S_IRWXG | S_IRWXO) == 0
                && leaseMetadata.st_nlink == 1
            guard leaseIsPrivate,
                  let databaseName = sqliteSourceBindingDatabaseName(
                      fromLeaseDescriptor: leaseDescriptor,
                      metadata: leaseMetadata
                  ) else {
                _ = Darwin.close(leaseDescriptor)
                continue
            }

            var currentDirectoryMetadata = stat()
            let directoryIsUnchanged = Darwin.lstat(
                candidate.path,
                &currentDirectoryMetadata
            ) == 0
                && currentDirectoryMetadata.st_dev == originalDirectoryMetadata.st_dev
                && currentDirectoryMetadata.st_ino == originalDirectoryMetadata.st_ino
                && currentDirectoryMetadata.st_mode & S_IFMT == S_IFDIR
                && currentDirectoryMetadata.st_uid == Darwin.geteuid()
                && currentDirectoryMetadata.st_mode & (S_IRWXG | S_IRWXO) == 0
            if directoryIsUnchanged,
               let childURLs = try? fileManager.contentsOfDirectory(
                   at: candidate,
                   includingPropertiesForKeys: nil,
                   options: [.skipsSubdirectoryDescendants]
               ) {
                let removableNames = Set([
                    sqliteSourceBindingLeaseName,
                    databaseName,
                    databaseName + "-wal",
                    databaseName + "-shm",
                    databaseName + "-journal",
                ])
                let childNames = Set(childURLs.map(\.lastPathComponent))
                let artifactURLs = childURLs.filter {
                    $0.lastPathComponent != sqliteSourceBindingLeaseName
                }
                let artifactsAreRegularFiles = artifactURLs.allSatisfy { url in
                    var metadata = stat()
                    return Darwin.lstat(url.path, &metadata) == 0
                        && metadata.st_mode & S_IFMT == S_IFREG
                }
                if childNames.isSubset(of: removableNames),
                   artifactsAreRegularFiles {
                    var removedEveryArtifact = true
                    for artifactURL in artifactURLs {
                        if Darwin.unlink(artifactURL.path) != 0 {
                            removedEveryArtifact = false
                            break
                        }
                    }
                    if removedEveryArtifact {
                        _ = Darwin.unlink(leaseURL.path)
                        _ = Darwin.rmdir(candidate.path)
                    }
                }
            }
            _ = Darwin.close(leaseDescriptor)
        }
    }

    private func fileSystemIsReadOnly(at path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.volumeIsReadOnlyKey]
        )
        return values?.volumeIsReadOnly == true
    }

    private func copyOptionalReadOnlyFile(
        from sourcePath: String,
        to destinationPath: String
    ) throws {
        let descriptor = Darwin.open(
            sourcePath,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw SQLiteDatabaseSnapshotError.sqlite(
                "cannot open source database sidecar"
            )
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw SQLiteDatabaseSnapshotError.sqlite(
                "source database sidecar is not a regular file"
            )
        }
        try copyValidatedReadOnlyFile(
            from: sourcePath,
            descriptor: descriptor,
            to: destinationPath,
            label: "source database sidecar"
        )
    }

    private func copyValidatedReadOnlyFile(
        from sourcePath: String,
        descriptor: Int32,
        to destinationPath: String,
        label: String
    ) throws {
        guard validatedSourcePath(sourcePath, matches: descriptor) else {
            throw SQLiteDatabaseSnapshotError.sqlite("\(label) changed while opening")
        }
        do {
            try fileManager.copyItem(atPath: sourcePath, toPath: destinationPath)
        } catch {
            throw SQLiteDatabaseSnapshotError.sqlite("cannot copy \(label)")
        }
        guard validatedSourcePath(sourcePath, matches: descriptor) else {
            _ = Darwin.unlink(destinationPath)
            throw SQLiteDatabaseSnapshotError.sqlite("\(label) changed while opening")
        }
        var destinationMetadata = stat()
        guard Darwin.lstat(destinationPath, &destinationMetadata) == 0,
              destinationMetadata.st_mode & S_IFMT == S_IFREG,
              Darwin.chmod(destinationPath, S_IRUSR | S_IWUSR) == 0 else {
            _ = Darwin.unlink(destinationPath)
            throw SQLiteDatabaseSnapshotError.sqlite("cannot secure \(label) copy")
        }
    }

    private func validatedSourcePath(
        _ path: String,
        matches descriptor: Int32
    ) -> Bool {
        var descriptorMetadata = stat()
        var pathMetadata = stat()
        return Darwin.fstat(descriptor, &descriptorMetadata) == 0
            && Darwin.lstat(path, &pathMetadata) == 0
            && descriptorMetadata.st_dev == pathMetadata.st_dev
            && descriptorMetadata.st_ino == pathMetadata.st_ino
            && pathMetadata.st_mode & S_IFMT == S_IFREG
    }

    private func enforceReadOnlySourceCopyMaximumBytes(
        sourcePath: String,
        sourceDescriptor: Int32,
        maximumBytes: Int?
    ) throws {
        guard let maximumBytes else { return }
        var total = try regularFileSize(descriptor: sourceDescriptor)
        for suffix in ["-wal", "-shm", "-journal"] {
            let descriptor = Darwin.open(
                sourcePath + suffix,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                if errno == ENOENT { continue }
                throw SQLiteDatabaseSnapshotError.sqlite(
                    "cannot open source database sidecar"
                )
            }
            defer { _ = Darwin.close(descriptor) }
            let size = try regularFileSize(descriptor: descriptor)
            let (updatedTotal, overflow) = total.addingReportingOverflow(size)
            guard !overflow else {
                throw SQLiteDatabaseSnapshotError.snapshotTooLarge(
                    maximumBytes: maximumBytes
                )
            }
            total = updatedTotal
        }
        guard total <= Int64(maximumBytes) else {
            throw SQLiteDatabaseSnapshotError.snapshotTooLarge(
                maximumBytes: maximumBytes
            )
        }
    }

    private func regularFileSize(descriptor: Int32) throws -> Int64 {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0 else {
            throw SQLiteDatabaseSnapshotError.sqlite(
                "source database artifact is not a regular file"
            )
        }
        return metadata.st_size
    }

    /// Opens special files without waiting for a peer and refuses symlinks.
    private func validatedRegularSourceDescriptor(path: String) throws -> Int32 {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw SQLiteDatabaseSnapshotError.sqlite("cannot open source database")
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            _ = Darwin.close(descriptor)
            throw SQLiteDatabaseSnapshotError.sqlite(
                "source database is not a regular file"
            )
        }
        return descriptor
    }

    private func linkOptionalRegularFile(from sourcePath: String, to destinationPath: String) throws {
        let descriptor = Darwin.open(
            sourcePath,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw SQLiteDatabaseSnapshotError.sqlite("cannot open source database sidecar")
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw SQLiteDatabaseSnapshotError.sqlite(
                "source database sidecar is not a regular file"
            )
        }
        try linkValidatedFile(
            from: sourcePath,
            descriptor: descriptor,
            to: destinationPath,
            label: "source database sidecar"
        )
    }

    /// SQLite considers a rollback journal hot when its header is live and it
    /// is large enough to contain a journal sector. Opening a hard-linked main
    /// database without that journal could expose pages from an interrupted
    /// transaction, so snapshotting fails closed instead.
    private func rejectHotRollbackJournal(path: String) throws {
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return }
            throw SQLiteDatabaseSnapshotError.sqlite(
                "cannot open source database sidecar"
            )
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw SQLiteDatabaseSnapshotError.sqlite(
                "source database sidecar is not a regular file"
            )
        }
        guard metadata.st_size > 512 else { return }
        var header = [UInt8](repeating: 0, count: 8)
        let bytesRead = header.withUnsafeMutableBytes { buffer in
            Darwin.pread(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard bytesRead == header.count else {
            throw SQLiteDatabaseSnapshotError.sqlite(
                "cannot read source database sidecar"
            )
        }
        let hotJournalMagic: [UInt8] = [
            0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7,
        ]
        guard header != hotJournalMagic else {
            throw SQLiteDatabaseSnapshotError.sqlite(
                "source database has a hot rollback journal"
            )
        }
    }

    private func linkValidatedFile(
        from sourcePath: String,
        descriptor: Int32,
        to destinationPath: String,
        label: String
    ) throws {
        guard Darwin.link(sourcePath, destinationPath) == 0 else {
            throw SQLiteDatabaseSnapshotError.sqlite("cannot bind \(label)")
        }

        var sourceMetadata = stat()
        var destinationMetadata = stat()
        guard Darwin.fstat(descriptor, &sourceMetadata) == 0,
              Darwin.lstat(destinationPath, &destinationMetadata) == 0,
              sourceMetadata.st_dev == destinationMetadata.st_dev,
              sourceMetadata.st_ino == destinationMetadata.st_ino,
              destinationMetadata.st_mode & S_IFMT == S_IFREG else {
            _ = Darwin.unlink(destinationPath)
            throw SQLiteDatabaseSnapshotError.sqlite("\(label) changed while opening")
        }
    }

    private func createPrivateDestinationFile(path: String) throws {
        let descriptor = Darwin.open(
            path,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw SQLiteDatabaseSnapshotError.sqlite("cannot create snapshot database")
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            _ = Darwin.unlink(path)
            throw SQLiteDatabaseSnapshotError.sqlite(
                "cannot restrict snapshot database permissions"
            )
        }
    }

    private func validateSnapshotDestination(path: String) throws {
        let destinationURL = URL(fileURLWithPath: path).standardizedFileURL
        let parentURL = destinationURL.deletingLastPathComponent()
        guard !destinationURL.lastPathComponent.isEmpty else {
            throw SQLiteDatabaseSnapshotError.sqlite(
                "snapshot destination path is invalid"
            )
        }
        var parentMetadata = stat()
        guard Darwin.lstat(parentURL.path, &parentMetadata) == 0,
              parentMetadata.st_mode & S_IFMT == S_IFDIR,
              parentMetadata.st_uid == Darwin.geteuid(),
              parentMetadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw SQLiteDatabaseSnapshotError.sqlite(
                "snapshot destination directory is not owner-controlled"
            )
        }
        for suffix in ["-wal", "-shm", "-journal"] {
            var sidecarMetadata = stat()
            if Darwin.lstat(destinationURL.path + suffix, &sidecarMetadata) == 0 {
                throw SQLiteDatabaseSnapshotError.sqlite(
                    "snapshot destination sidecars already exist"
                )
            }
            guard errno == ENOENT else {
                throw SQLiteDatabaseSnapshotError.sqlite(
                    "cannot inspect snapshot destination sidecars"
                )
            }
        }
    }

    private func createPrivateDirectory(in parentURL: URL, prefix: String) throws -> URL {
        for _ in 0..<8 {
            let directoryURL = parentURL.appendingPathComponent(
                "\(prefix)-\(UUID().uuidString)",
                isDirectory: true
            )
            guard Darwin.mkdir(directoryURL.path, S_IRWXU) == 0 else {
                if errno == EEXIST { continue }
                throw SQLiteDatabaseSnapshotError.sqlite(
                    "cannot create private snapshot directory"
                )
            }

            let descriptor = Darwin.open(
                directoryURL.path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                _ = Darwin.rmdir(directoryURL.path)
                throw SQLiteDatabaseSnapshotError.sqlite(
                    "cannot open private snapshot directory"
                )
            }
            let permissionResult = Darwin.fchmod(descriptor, S_IRWXU)
            _ = Darwin.close(descriptor)
            guard permissionResult == 0 else {
                _ = Darwin.rmdir(directoryURL.path)
                throw SQLiteDatabaseSnapshotError.sqlite(
                    "cannot restrict snapshot directory permissions"
                )
            }
            return directoryURL
        }
        throw SQLiteDatabaseSnapshotError.sqlite(
            "cannot allocate private snapshot directory"
        )
    }

    private func restrictSnapshotArtifactPermissions(destinationPath: String) throws {
        for path in [
            destinationPath,
            destinationPath + "-wal",
            destinationPath + "-shm",
            destinationPath + "-journal",
        ] {
            let descriptor = Darwin.open(
                path,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                if errno == ENOENT { continue }
                throw SQLiteDatabaseSnapshotError.sqlite(
                    "cannot open snapshot artifact"
                )
            }
            let permissionResult = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
            _ = Darwin.close(descriptor)
            guard permissionResult == 0 else {
                throw SQLiteDatabaseSnapshotError.sqlite(
                    "cannot restrict snapshot artifact permissions"
                )
            }
        }
    }

    private func removeSnapshotSidecars(destinationPath: String) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecarPath = destinationPath + suffix
            guard fileManager.fileExists(atPath: sidecarPath) else { continue }
            do {
                try fileManager.removeItem(atPath: sidecarPath)
            } catch {
                throw SQLiteDatabaseSnapshotError.sqlite(
                    "cannot remove snapshot sidecar: \(error.localizedDescription)"
                )
            }
        }
    }

    private func removeSnapshotArtifacts(destinationPath: String) {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            _ = Darwin.unlink(destinationPath + suffix)
        }
    }

    private func makeSnapshotStandalone(_ database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        let result = sqlite3_exec(
            database,
            "PRAGMA journal_mode = DELETE",
            nil,
            nil,
            &errorMessage
        )
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? sqliteMessage(database, fallback: sqliteErrorString(result))
            sqlite3_free(errorMessage)
            throw SQLiteDatabaseSnapshotError.sqlite(
                "cannot finalize standalone snapshot: \(message)"
            )
        }
    }

    private func databasePageSize(_ database: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA page_size", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            throw SQLiteDatabaseSnapshotError.sqlite(
                sqliteMessage(database, fallback: "cannot read database page size")
            )
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteDatabaseSnapshotError.sqlite(
                sqliteMessage(database, fallback: "cannot read database page size")
            )
        }
        let pageSize = sqlite3_column_int64(statement, 0)
        guard pageSize > 0 else {
            throw SQLiteDatabaseSnapshotError.sqlite("database reported an invalid page size")
        }
        return pageSize
    }

    private func enforceMaximumBytes(
        backup: OpaquePointer,
        pageSize: Int64,
        maximumBytes: Int?,
        sourceDatabasePath: String
    ) throws {
        guard let maximumBytes else { return }
        let maximumBytes64 = Int64(maximumBytes)
        let sidecarBytes = try boundSidecarBytes(databasePath: sourceDatabasePath)
        let pageCount = Int64(sqlite3_backup_pagecount(backup))
        guard pageCount >= 0,
              sidecarBytes <= maximumBytes64,
              pageCount <= (maximumBytes64 - sidecarBytes) / pageSize else {
            throw SQLiteDatabaseSnapshotError.snapshotTooLarge(
                maximumBytes: maximumBytes
            )
        }
    }

    private func enforceMaximumSidecarBytes(
        databasePath: String,
        maximumBytes: Int?
    ) throws {
        guard let maximumBytes,
              try boundSidecarBytes(databasePath: databasePath) > Int64(maximumBytes) else {
            return
        }
        throw SQLiteDatabaseSnapshotError.snapshotTooLarge(
            maximumBytes: maximumBytes
        )
    }

    private func boundSidecarBytes(databasePath: String) throws -> Int64 {
        var total: Int64 = 0
        for suffix in ["-wal", "-shm", "-journal"] {
            let descriptor = Darwin.open(
                databasePath + suffix,
                O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
            )
            guard descriptor >= 0 else {
                if errno == ENOENT { continue }
                throw SQLiteDatabaseSnapshotError.sqlite(
                    "cannot open bound database sidecar"
                )
            }
            var metadata = stat()
            let metadataResult = Darwin.fstat(descriptor, &metadata)
            _ = Darwin.close(descriptor)
            guard metadataResult == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_size >= 0 else {
                throw SQLiteDatabaseSnapshotError.sqlite(
                    "bound database sidecar is not a regular file"
                )
            }
            let (updatedTotal, overflow) = total.addingReportingOverflow(metadata.st_size)
            guard !overflow else {
                throw SQLiteDatabaseSnapshotError.sqlite(
                    "bound database sidecar size overflow"
                )
            }
            total = updatedTotal
        }
        return total
    }

    private func sqliteMessage(
        _ database: OpaquePointer?,
        fallback: String
    ) -> String {
        guard let database,
              let message = sqlite3_errmsg(database) else {
            return fallback
        }
        return String(cString: message)
    }

    private func sqliteErrorString(_ result: Int32) -> String {
        sqlite3_errstr(result).map(String.init(cString:)) ?? "SQLite error \(result)"
    }
}

private func sqliteSourceBindingDirectoryNameIsGenerated(_ name: String) -> Bool {
    let prefix = sqliteSourceBindingDirectoryPrefix + "-"
    guard name.hasPrefix(prefix) else { return false }
    let token = String(name.dropFirst(prefix.count))
    return UUID(uuidString: token)?.uuidString == token
}

private func sqliteSourceBindingDatabaseNameIsValid(_ name: String) -> Bool {
    !name.isEmpty
        && name != "."
        && name != ".."
        && name != sqliteSourceBindingLeaseName
        && !name.contains("/")
        && URL(fileURLWithPath: name).lastPathComponent == name
}

private func sqliteSourceBindingDatabaseName(
    fromLeaseDescriptor descriptor: Int32,
    metadata: stat
) -> String? {
    guard metadata.st_size > 0,
          metadata.st_size <= sqliteSourceBindingLeaseMaximumBytes else {
        return nil
    }
    var bytes = [UInt8](repeating: 0, count: Int(metadata.st_size))
    var offset = 0
    while offset < bytes.count {
        let remainingByteCount = bytes.count - offset
        let bytesRead = bytes.withUnsafeMutableBytes { buffer in
            Darwin.pread(
                descriptor,
                buffer.baseAddress?.advanced(by: offset),
                remainingByteCount,
                off_t(offset)
            )
        }
        guard bytesRead > 0 else { return nil }
        offset += bytesRead
    }
    guard let object = try? JSONSerialization.jsonObject(with: Data(bytes)),
          let manifest = object as? [String: Any],
          manifest["version"] as? Int == sqliteSourceBindingLeaseVersion,
          let databaseName = manifest["databaseName"] as? String,
          sqliteSourceBindingDatabaseNameIsValid(databaseName) else {
        return nil
    }
    return databaseName
}
