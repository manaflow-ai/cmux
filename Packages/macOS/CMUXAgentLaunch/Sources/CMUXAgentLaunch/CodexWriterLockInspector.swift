import Darwin
import Foundation

/// Inspects Codex's cross-process writer lock without creating or removing files.
///
/// The probe releases its descriptor before returning. Codex remains the final
/// authority if another writer starts between this preflight and TUI startup.
public struct CodexWriterLockInspector: Sendable {
    /// Creates a stateless kernel lock inspector.
    public init() {}

    /// Probes an exact UUID thread under the supplied effective Codex home.
    ///
    /// - Parameters:
    ///   - sessionID: The Codex thread UUID, normalized to Codex's filename spelling.
    ///   - codexHome: The effective state directory of the process being launched.
    /// - Returns: Lock availability, or unavailable for malformed/unreadable state.
    public func inspect(sessionID: String, codexHome: String) -> CodexWriterLockInspection {
        let threadID = UUID(uuidString: sessionID)?.uuidString.lowercased()
        let home: String
        if !codexHome.utf8.contains(0), let resolved = realpath(codexHome, nil) {
            home = String(cString: resolved)
            free(resolved)
        } else {
            home = codexHome
        }
        let path = home + "/thread-writer-locks/" + (threadID ?? "invalid-thread") + ".lock"
        func result(_ state: CodexWriterLockInspection.State, _ file: stat? = nil) -> CodexWriterLockInspection {
            CodexWriterLockInspection(
                state: state, codexHome: home, lockPath: path,
                device: file?.st_dev, inode: file?.st_ino
            )
        }
        guard threadID != nil, codexHome.hasPrefix("/"), !codexHome.utf8.contains(0) else {
            return result(.unavailable)
        }
        // A cross-process flock is required to observe Codex's own lock; an
        // actor or file-existence check cannot establish this kernel invariant.
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return result(errno == ENOENT ? .available : .unavailable) }
        defer { close(fd) }
        var file = stat()
        guard fstat(fd, &file) == 0, file.st_mode & S_IFMT == S_IFREG else {
            return result(.unavailable)
        }
        let status = flock(fd, LOCK_EX | LOCK_NB)
        let error = errno
        // Closing our own descriptor releases only the probe's acquisition.
        var current = stat()
        guard lstat(path, &current) == 0,
              current.st_dev == file.st_dev, current.st_ino == file.st_ino else {
            return result(.unavailable)
        }
        if status == 0 { return result(.available, file) }
        return result(error == EWOULDBLOCK ? .active : .unavailable, file)
    }
}
