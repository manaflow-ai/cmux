import Darwin
import Foundation

/// Reclaims expired editor handoff copies while enforcing bounded temporary storage.
public struct ProjectFileTemporaryCopyCleaner {
    private static let maximumFileCount = 256
    private static let maximumByteCount: Int64 = 256 * 1024 * 1024

    private let fileManager: FileManager
    private let now: Date

    /// Creates a temporary-copy cleaner with injectable filesystem and clock inputs.
    ///
    /// - Parameters:
    ///   - fileManager: Filesystem used to enumerate temporary copies.
    ///   - now: Reference time used to determine whether a copy's lease expired.
    public init(fileManager: FileManager = .default, now: Date = .now) {
        self.fileManager = fileManager
        self.now = now
    }

    /// Removes expired copies beyond the bounds and evaluates a requested reservation.
    ///
    /// Fresh copies retain a 24-hour lease and are never evicted to satisfy a
    /// reservation. Only regular files whose names begin with
    /// `cmux-project-file-` are considered.
    ///
    /// - Parameters:
    ///   - directory: Directory containing editor handoff copies.
    ///   - reservingBytes: Bytes needed by the pending handoff.
    ///   - reservingFileCount: File slots needed by the pending handoff.
    /// - Returns: Whether the protected and retained copies leave room for the reservation.
    @discardableResult
    public func cleanup(
        in directory: URL,
        reservingBytes: Int64 = 0,
        reservingFileCount: Int = 0
    ) -> Bool {
        guard reservingBytes >= 0, reservingBytes <= Self.maximumByteCount else {
            return false
        }
        guard reservingFileCount >= 0, reservingFileCount <= Self.maximumFileCount else {
            return false
        }
        // LaunchServices has no completion callback for the editor that owns
        // this handoff. Treat the age threshold as a lease: fresh copies are
        // never evicted by count/bytes while an editor may still use them.
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return true }
        let directoryPath = directory.standardizedFileURL.path
        var reclaimable: [(url: URL, size: Int64, modifiedAt: Date)] = []
        var protectedCount = 0
        var protectedBytes: Int64 = 0
        for case let entry as URL in enumerator {
            guard entry.deletingLastPathComponent().standardizedFileURL.path == directoryPath,
                  entry.lastPathComponent.hasPrefix("cmux-project-file-") else {
                continue
            }
            var status = stat()
            guard lstat(entry.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_size >= 0 else {
                continue
            }
            let modifiedAt = Date(timeIntervalSince1970: Double(status.st_mtimespec.tv_sec))
            guard modifiedAt < cutoff else {
                // Preserve the active lease even if many editor handoffs are
                // open. A later cleanup after expiry reclaims this copy.
                protectedCount += 1
                let size = Int64(status.st_size)
                protectedBytes = protectedBytes > Self.maximumByteCount - size
                    ? Self.maximumByteCount
                    : protectedBytes + size
                continue
            }
            let candidate = (
                url: entry,
                size: Int64(status.st_size),
                modifiedAt: modifiedAt
            )
            if reclaimable.count < Self.maximumFileCount {
                reclaimable.append(candidate)
                continue
            }
            guard let oldestIndex = reclaimable.indices.min(by: { lhs, rhs in
                if reclaimable[lhs].modifiedAt != reclaimable[rhs].modifiedAt {
                    return reclaimable[lhs].modifiedAt < reclaimable[rhs].modifiedAt
                }
                return reclaimable[lhs].url.path < reclaimable[rhs].url.path
            }) else {
                continue
            }
            let oldest = reclaimable[oldestIndex]
            let candidateIsNewer = candidate.modifiedAt > oldest.modifiedAt
                || (candidate.modifiedAt == oldest.modifiedAt
                    && candidate.url.path > oldest.url.path)
            if candidateIsNewer {
                _ = unlink(oldest.url.path)
                reclaimable[oldestIndex] = candidate
            } else {
                _ = unlink(candidate.url.path)
            }
        }
        reclaimable.sort {
            if $0.modifiedAt != $1.modifiedAt {
                return $0.modifiedAt > $1.modifiedAt
            }
            return $0.url.path > $1.url.path
        }
        var retainedBytes: Int64 = 0
        var retainedCount = 0
        for entry in reclaimable {
            guard entry.size <= Self.maximumByteCount,
                  retainedBytes <= Self.maximumByteCount - entry.size else {
                _ = unlink(entry.url.path)
                continue
            }
            retainedBytes += entry.size
            retainedCount += 1
        }
        // A zero-byte note/artifact still creates a leased temporary file, so
        // reserve its slot independently of the byte reservation.
        let requestedCount = reservingFileCount
        guard protectedCount <= Self.maximumFileCount - requestedCount,
              retainedCount <= Self.maximumFileCount - requestedCount - protectedCount,
              protectedBytes <= Self.maximumByteCount,
              retainedBytes <= Self.maximumByteCount - protectedBytes,
              reservingBytes <= Self.maximumByteCount - protectedBytes - retainedBytes else {
            return false
        }
        return true
    }
}
