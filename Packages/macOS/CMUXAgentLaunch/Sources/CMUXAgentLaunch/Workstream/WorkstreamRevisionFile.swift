import Foundation
import Dispatch
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owns bounded revision metadata reads and cross-process high-water updates.
///
/// The URL and queue are immutable. Each read owns its handle; atomic replacement
/// gives readers a complete value, and flock serializes writers across processes.
final class WorkstreamRevisionFile: @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager
    // A kernel file lock can wait for another process. Bridge that blocking I/O
    // on one dedicated GCD queue, never on a Swift cooperative executor. Store
    // flush awaits the continuation, including time spent waiting for the lock.
    private let queue = DispatchQueue(label: "com.cmuxterm.workstream-revision")

    init(url: URL, fileManager: FileManager) {
        self.url = url
        self.fileManager = fileManager
    }

    func read() -> UInt64 {
        guard let file = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? file.close() }
        // UInt64 has at most 20 decimal digits; reject oversized metadata at
        // the read boundary instead of allocating the entire malformed file.
        guard let data = try? file.read(upToCount: 65), data.count <= 64,
              let text = String(data: data, encoding: .utf8),
              let value = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return 0 }
        return min(value, UInt64(Int.max - 1))
    }

    func record(_ revision: Int) async throws {
        guard revision > 0 else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.recordLocked(revision)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func recordLocked(_ revision: Int) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Never unlink this sibling: every writer must lock the same inode even
        // while the revision value itself is replaced atomically.
        let descriptor = open(url.appendingPathExtension("lock").path,
                              O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }
        // Re-read after acquiring the lock. Atomic rename alone could let an
        // app startup and CLI clear overwrite a newer floor with an older one.
        let current = read()
        let next = max(current, UInt64(revision))
        guard next > current else { return }
        try Data(String(next).utf8).write(to: url, options: .atomic)
    }
}
