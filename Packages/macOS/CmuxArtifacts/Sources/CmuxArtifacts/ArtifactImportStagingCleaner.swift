import Darwin
import Foundation

/// Reclaims abandoned import batches without disturbing leases held by other processes.
struct ArtifactImportStagingCleaner {
    let fileManager: FileManager
    let now: @Sendable () -> Date
    let scanLimit: Int
    let malformedEntryGracePeriod: TimeInterval

    init(
        fileManager: FileManager,
        now: @escaping @Sendable () -> Date,
        scanLimit: Int = 256,
        malformedEntryGracePeriod: TimeInterval = 6 * 60 * 60
    ) {
        self.fileManager = fileManager
        self.now = now
        self.scanLimit = max(1, scanLimit)
        self.malformedEntryGracePeriod = max(0, malformedEntryGracePeriod)
    }

    func reclaimAbandonedBatches(root: URL) {
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(
                  at: root,
                  includingPropertiesForKeys: [
                      .contentModificationDateKey,
                      .isDirectoryKey,
                      .isSymbolicLinkKey,
                  ],
                  options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
              ) else {
            return
        }
        var inspected = 0
        for case let entry as URL in enumerator {
            guard inspected < scanLimit else { break }
            inspected += 1
            reclaim(entry)
        }
    }

    private func reclaim(_ entry: URL) {
        let name = entry.lastPathComponent
        guard name.hasSuffix(ArtifactImportStagingLease.batchSuffix)
                || name.hasSuffix(ArtifactImportStagingLease.claimSuffix) else {
            return
        }
        guard let values = try? entry.resourceValues(forKeys: [
            .contentModificationDateKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ]) else {
            return
        }
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            removeIfStale(entry, modifiedAt: values.contentModificationDate)
            return
        }
        let leasePath = entry.appendingPathComponent(
            ArtifactImportStagingLease.leaseFilename,
            isDirectory: false
        ).path
        let descriptor = Darwin.open(leasePath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            removeIfStale(entry, modifiedAt: values.contentModificationDate)
            return
        }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            removeIfStale(entry, modifiedAt: values.contentModificationDate)
            return
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { _ = flock(descriptor, LOCK_UN) }
        try? fileManager.removeItem(at: entry)
    }

    private func removeIfStale(_ entry: URL, modifiedAt: Date?) {
        guard let modifiedAt,
              now().timeIntervalSince(modifiedAt) >= malformedEntryGracePeriod else {
            return
        }
        try? fileManager.removeItem(at: entry)
    }
}
