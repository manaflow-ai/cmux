#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Dispatch
import Foundation

/// Cross-process serialization for writers of one label store file.
///
/// Actor isolation only serializes calls that go through one store instance.
/// Two `cmux sessions label` processes, or two stores built from the same
/// directory in one process, would otherwise read the document, each add their
/// own record, and each write the result: the second write drops the first
/// record and both callers are told they succeeded. Every mutation takes this
/// lock around the whole read-modify-write, so the loser waits instead.
///
/// The lock lives in a sidecar file next to the store and is never unlinked:
/// replacing it would hand two writers two different inodes, which is two
/// locks. Waiting happens off the actor so a held lock does not block the
/// caller's cooperative thread.
struct AgentSessionLabelStoreLock: Sendable {
    /// Suffix appended to the store path to get the sidecar lock path.
    static let fileSuffix = ".cmux-write.lock"

    private static let waitQueue = DispatchQueue(
        label: "com.cmux.agent-session-labels.write-lock",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let descriptor: Int32

    /// Blocks until this process owns the lock for `target`.
    ///
    /// - Parameter target: the store file the lock protects. Its parent
    ///   directory is created if it does not exist yet, because the first
    ///   writer takes the lock before there is anything to write.
    /// - Returns: the held lock. The caller must ``release()`` it.
    /// - Throws: `POSIXError` when the sidecar cannot be opened or locked, or a
    ///   `CocoaError` when its directory cannot be created.
    static func acquire(target: URL) async throws -> AgentSessionLabelStoreLock {
        try await withCheckedThrowingContinuation { continuation in
            waitQueue.async {
                continuation.resume(with: Result {
                    try AgentSessionLabelStoreLock(blockingTarget: target)
                })
            }
        }
    }

    private init(blockingTarget target: URL) throws {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(
            target.path + Self.fileSuffix,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        // A sidecar that is not a plain file this user owns is not a lock this
        // process may trust, so refuse rather than write beside it.
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1 else {
            close(descriptor)
            throw POSIXError(.EPERM)
        }

        while flock(descriptor, LOCK_EX) != 0 {
            let code = errno
            guard code == EINTR else {
                close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
        }
        self.descriptor = descriptor
    }

    /// Hands the lock back so a waiting writer can proceed.
    func release() {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
