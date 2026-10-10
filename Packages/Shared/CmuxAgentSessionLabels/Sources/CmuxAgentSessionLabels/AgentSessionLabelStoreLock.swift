#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
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
/// locks. Waiting is a cooperative sleep between non-blocking attempts rather
/// than a blocking `flock`, so a caller that is cancelled stops waiting, a
/// writer that is wedged while holding the lock fails the waiter by its
/// deadline instead of hanging it, and no thread is parked while waiting.
struct AgentSessionLabelStoreLock: Sendable {
    /// Suffix appended to the store path to get the sidecar lock path.
    static let fileSuffix = ".cmux-write.lock"

    private let descriptor: Int32

    /// Waits until this process owns the lock for `target`.
    ///
    /// - Parameters:
    ///   - target: the store file the lock protects. Its parent directory is
    ///     created if it does not exist yet, because the first writer takes the
    ///     lock before there is anything to write.
    ///   - fileManager: the file manager the directory is created through, so a
    ///     caller that injects one sees this call too.
    ///   - timeout: how long to wait for a peer that holds the lock.
    /// - Returns: the held lock. The caller must ``release()`` it.
    /// - Throws: ``AgentSessionLabelStoreLockError`` when the sidecar cannot be
    ///   opened, trusted or locked within `timeout`, and `CancellationError`
    ///   when the caller is cancelled while waiting.
    static func acquire(
        target: URL,
        fileManager: FileManager = .default,
        timeout: Duration
    ) async throws -> AgentSessionLabelStoreLock {
        do {
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw AgentSessionLabelStoreLockError.directoryUnavailable(
                reason: (error as NSError).localizedDescription
            )
        }
        let descriptor = open(
            target.path + Self.fileSuffix,
            O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard descriptor >= 0 else {
            throw AgentSessionLabelStoreLockError.cannotOpen(code: errno)
        }

        // A sidecar that is not a plain file this user owns is not a lock this
        // process may trust, so refuse rather than write beside it. The link
        // count is deliberately not checked: a hardlink snapshot of the state
        // directory, which `cp -al` and `rsync --link-dest` both make, would
        // otherwise fail every later write for good, and anyone who can hardlink
        // in that directory can write the sidecar directly anyway.
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid() else {
            close(descriptor)
            throw AgentSessionLabelStoreLockError.untrustedLockFile
        }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        var wait: Duration = .milliseconds(2)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return AgentSessionLabelStoreLock(descriptor: descriptor)
            }
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                close(descriptor)
                throw AgentSessionLabelStoreLockError.cannotLock(code: code)
            }
            guard ContinuousClock.now < deadline else {
                close(descriptor)
                throw AgentSessionLabelStoreLockError.busy(timeout: timeout)
            }
            do {
                try await Task.sleep(for: wait)
            } catch {
                // Cancellation, which is the caller's answer and not a failure of
                // the lock. The descriptor closes here because nobody else holds it.
                close(descriptor)
                throw error
            }
            wait = min(wait * 2, .milliseconds(25))
        }
    }

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Hands the lock back so a waiting writer can proceed.
    ///
    /// Call it once: this is a value whose `release()` closes a descriptor, so a
    /// second call would close a descriptor this process may have reopened for
    /// something else. There is one call site, in the store's `withWriteLock`.
    func release() {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// Why the store's write lock could not be taken.
///
/// Every case renders as a clause the store folds into
/// ``AgentSessionLabelError/unwritableFile(path:reason:)``, so a caller prints
/// one sentence naming the file rather than a bare `POSIXError`.
enum AgentSessionLabelStoreLockError: Error, Equatable {
    /// The store's directory does not exist and could not be created.
    case directoryUnavailable(reason: String)
    /// The sidecar could not be opened. The usual cause is a directory this
    /// process may not write, or a sidecar that is a symlink.
    case cannotOpen(code: Int32)
    /// The sidecar is not a plain file owned by this user.
    case untrustedLockFile
    /// The sidecar could not be locked for a reason other than contention, such
    /// as a file system with no `flock`.
    case cannotLock(code: Int32)
    /// A peer held the lock past the deadline.
    case busy(timeout: Duration)

    /// The clause the store puts after the path in its message.
    var reason: String {
        switch self {
        case let .directoryUnavailable(reason):
            return "its directory could not be created: \(reason)"
        case let .cannotOpen(code):
            return "its lock file could not be opened: \(Self.describe(code))"
        case .untrustedLockFile:
            return "its lock file is not a plain file this user owns"
        case let .cannotLock(code):
            return "its lock file could not be locked: \(Self.describe(code))"
        case let .busy(timeout):
            return "another writer held the lock for more than \(Self.describe(timeout))"
        }
    }

    private static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    private static func describe(_ timeout: Duration) -> String {
        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        if seconds >= 1 {
            return "\(String(format: "%g", seconds)) seconds"
        }
        return "\(String(format: "%g", seconds * 1000)) ms"
    }
}
