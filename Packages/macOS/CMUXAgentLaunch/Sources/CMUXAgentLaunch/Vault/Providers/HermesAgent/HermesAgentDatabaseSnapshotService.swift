import Foundation

/// Creates bounded, cancellation-aware snapshots of the Hermes SQLite store.
struct HermesAgentDatabaseSnapshotService {
    private let fileManager: FileManager
    private let copyChunkBytes: Int

    init(
        fileManager: FileManager = .default,
        copyChunkBytes: Int = 256 * 1_024
    ) {
        self.fileManager = fileManager
        self.copyChunkBytes = max(1, copyChunkBytes)
    }

    func make(
        stateDBPath: String,
        prefix: String,
        maximumTotalBytes: Int? = nil
    ) throws -> HermesAgentDatabaseSnapshot? {
        guard fileManager.fileExists(atPath: stateDBPath) else { return nil }
        if let maximumTotalBytes, maximumTotalBytes < 0 {
            throw HermesAgentIndexError.snapshotTooLarge(maximumBytes: maximumTotalBytes)
        }
        try Task.checkCancellation()

        let snapshotDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: snapshotDirectory,
            withIntermediateDirectories: true
        )

        let snapshotDatabase = snapshotDirectory.appendingPathComponent(
            "state.db",
            isDirectory: false
        )
        var copiedBytes = 0
        do {
            try copyFile(
                from: URL(fileURLWithPath: stateDBPath, isDirectory: false),
                to: snapshotDatabase,
                maximumTotalBytes: maximumTotalBytes,
                copiedBytes: &copiedBytes
            )
            for sidecar in ["-wal", "-shm"] {
                let sourcePath = stateDBPath + sidecar
                guard fileManager.fileExists(atPath: sourcePath) else { continue }
                try copyFile(
                    from: URL(fileURLWithPath: sourcePath, isDirectory: false),
                    to: URL(
                        fileURLWithPath: snapshotDatabase.path + sidecar,
                        isDirectory: false
                    ),
                    maximumTotalBytes: maximumTotalBytes,
                    copiedBytes: &copiedBytes
                )
            }
        } catch {
            try? fileManager.removeItem(at: snapshotDirectory)
            throw error
        }

        return HermesAgentDatabaseSnapshot(
            databaseURL: snapshotDatabase,
            directoryURL: snapshotDirectory,
            fileManager: fileManager
        )
    }

    private func copyFile(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumTotalBytes: Int?,
        copiedBytes: inout Int
    ) throws {
        try Task.checkCancellation()
        try Data().write(to: destinationURL, options: .withoutOverwriting)
        let source = try FileHandle(forReadingFrom: sourceURL)
        defer { try? source.close() }
        let destination = try FileHandle(forWritingTo: destinationURL)
        defer { try? destination.close() }

        while true {
            try Task.checkCancellation()
            let readCount: Int
            if let maximumTotalBytes {
                let remaining = maximumTotalBytes - copiedBytes
                guard remaining >= 0 else {
                    throw HermesAgentIndexError.snapshotTooLarge(
                        maximumBytes: maximumTotalBytes
                    )
                }
                readCount = min(copyChunkBytes, max(1, remaining))
            } else {
                readCount = copyChunkBytes
            }
            guard let data = try source.read(upToCount: readCount), !data.isEmpty else {
                return
            }
            if let maximumTotalBytes,
               data.count > maximumTotalBytes - copiedBytes {
                throw HermesAgentIndexError.snapshotTooLarge(
                    maximumBytes: maximumTotalBytes
                )
            }
            try destination.write(contentsOf: data)
            copiedBytes += data.count
        }
    }
}
