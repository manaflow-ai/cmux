import Darwin
import Foundation

/// Inspects Codex's cross-process writer lock without creating or removing files.
public struct CodexWriterLockInspector: Sendable {
    public init() {}

    public func inspect(sessionID: String, codexHome: String) -> CodexWriterLockInspection {
        let normalizedID = UUID(uuidString: sessionID)?.uuidString.lowercased()
        let home = standardizedHome(codexHome)
        let lockPath = home + "/thread-writer-locks/" + (normalizedID ?? "invalid-thread") + ".lock"
        guard normalizedID != nil, codexHome.hasPrefix("/"), !codexHome.utf8.contains(0) else {
            return CodexWriterLockInspection(state: .unavailable, codexHome: home, lockPath: lockPath)
        }
        let locksDirectory = home + "/thread-writer-locks"
        guard directoryExists(atPath: home), directoryExists(atPath: locksDirectory) else {
            return CodexWriterLockInspection(state: .unavailable, codexHome: home, lockPath: lockPath)
        }
        let descriptor = open(lockPath, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            return CodexWriterLockInspection(
                state: errno == ENOENT ? .available : .unavailable,
                codexHome: home,
                lockPath: lockPath
            )
        }
        defer { close(descriptor) }
        var file = stat()
        guard fstat(descriptor, &file) == 0, file.st_mode & S_IFMT == S_IFREG else {
            return CodexWriterLockInspection(state: .unavailable, codexHome: home, lockPath: lockPath)
        }
        let status = flock(descriptor, LOCK_EX | LOCK_NB)
        let lockError = errno
        var currentFile = stat()
        guard lstat(lockPath, &currentFile) == 0,
              currentFile.st_dev == file.st_dev,
              currentFile.st_ino == file.st_ino else {
            return CodexWriterLockInspection(state: .unavailable, codexHome: home, lockPath: lockPath)
        }
        let device = Int32(file.st_dev)
        let inode = UInt64(file.st_ino)
        if status == 0 {
            return CodexWriterLockInspection(
                state: .available,
                codexHome: home,
                lockPath: lockPath,
                device: device,
                inode: inode
            )
        }
        return CodexWriterLockInspection(
            state: lockError == EWOULDBLOCK ? .active : .unavailable,
            codexHome: home,
            lockPath: lockPath,
            device: device,
            inode: inode
        )
    }

    private func standardizedHome(_ path: String) -> String {
        guard !path.utf8.contains(0), let resolved = realpath(path, nil) else {
            return path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func directoryExists(atPath path: String) -> Bool {
        var file = stat()
        guard lstat(path, &file) == 0 else { return false }
        return file.st_mode & S_IFMT == S_IFDIR
    }
}
