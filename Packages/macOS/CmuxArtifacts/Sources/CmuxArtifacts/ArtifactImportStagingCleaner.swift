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
        let rootDescriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard rootDescriptor >= 0 else {
            return
        }
        defer { _ = Darwin.close(rootDescriptor) }
        guard let enumerator = fileManager.enumerator(
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
            reclaim(entry, rootDescriptor: rootDescriptor)
        }
    }

    private func reclaim(_ entry: URL, rootDescriptor: Int32) {
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
            removeIfStale(
                name: name,
                rootDescriptor: rootDescriptor,
                modifiedAt: values.contentModificationDate
            )
            return
        }
        let entryDescriptor = name.withCString { pointer in
            Darwin.openat(
                rootDescriptor,
                pointer,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        guard entryDescriptor >= 0 else {
            removeIfStale(
                name: name,
                rootDescriptor: rootDescriptor,
                modifiedAt: values.contentModificationDate
            )
            return
        }
        defer { _ = close(entryDescriptor) }
        let descriptor = ArtifactImportStagingLease.leaseFilename.withCString { pointer in
            Darwin.openat(
                entryDescriptor,
                pointer,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            removeIfStale(
                name: name,
                rootDescriptor: rootDescriptor,
                directoryDescriptor: entryDescriptor,
                directoryURL: entry,
                modifiedAt: values.contentModificationDate
            )
            return
        }
        defer { _ = close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            removeIfStale(
                name: name,
                rootDescriptor: rootDescriptor,
                directoryDescriptor: entryDescriptor,
                directoryURL: entry,
                modifiedAt: values.contentModificationDate
            )
            return
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { _ = flock(descriptor, LOCK_UN) }
        removeDirectoryContents(entryDescriptor, directoryURL: entry)
        _ = name.withCString { pointer in
            Darwin.unlinkat(rootDescriptor, pointer, AT_REMOVEDIR)
        }
    }

    private func removeIfStale(
        name: String,
        rootDescriptor: Int32,
        directoryDescriptor: Int32? = nil,
        directoryURL: URL? = nil,
        modifiedAt: Date?
    ) {
        guard let modifiedAt,
              now().timeIntervalSince(modifiedAt) >= malformedEntryGracePeriod else {
            return
        }
        if let directoryDescriptor {
            removeDirectoryContents(directoryDescriptor, directoryURL: directoryURL)
            _ = name.withCString { pointer in
                Darwin.unlinkat(rootDescriptor, pointer, AT_REMOVEDIR)
            }
        } else {
            _ = name.withCString { pointer in
                Darwin.unlinkat(rootDescriptor, pointer, 0)
            }
        }
    }

    private func removeDirectoryContents(_ descriptor: Int32, directoryURL: URL?) {
        guard let directoryURL,
              let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) else {
            return
        }
        for name in names where name != "." && name != ".." {
            _ = name.withCString { pointer in
                Darwin.unlinkat(descriptor, pointer, 0)
            }
        }
    }
}
