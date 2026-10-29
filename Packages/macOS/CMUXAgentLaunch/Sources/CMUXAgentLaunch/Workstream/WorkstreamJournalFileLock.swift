import Dispatch
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A stable inode lock shared by the app and `cmux feed clear`.
///
/// The journal itself may be replaced or unlinked, so the lock lives beside it
/// and is never removed. Kernel lock acquisition runs on a private queue rather
/// than blocking a Swift cooperative executor.
final class WorkstreamJournalFileLock: @unchecked Sendable {
    private let lockURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.cmuxterm.workstream-journal-lock")

    init(fileURL: URL, fileManager: FileManager) {
        self.lockURL = fileURL.appendingPathExtension("lock")
        self.fileManager = fileManager
    }

    func acquire() async throws -> WorkstreamJournalFileLockLease {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.fileManager.createDirectory(
                        at: self.lockURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    let descriptor = open(
                        self.lockURL.path,
                        O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                        0o600
                    )
                    guard descriptor >= 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    guard flock(descriptor, LOCK_EX) == 0 else {
                        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        _ = close(descriptor)
                        throw error
                    }
                    continuation.resume(returning: WorkstreamJournalFileLockLease(descriptor: descriptor))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
