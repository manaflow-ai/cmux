import Darwin
public import Foundation

/// Opens diagnostic log files for appending, such as the debug logs under `/tmp`.
///
/// A log in a shared directory can already exist under another user's control,
/// so the path is opened without following a symlink and kept only when it is a
/// regular file this user owns with no other hard link. New files are 0600.
public enum OwnedLogFile {
    /// Returns an append-only handle to the file at `path`, creating the file
    /// when missing, or nil when it cannot be opened or is not private.
    public static func openForAppending(atPath path: String) -> FileHandle? {
        // O_NONBLOCK keeps a FIFO at the path from blocking the open; it is
        // rejected by the regular-file check below.
        let fd = Darwin.open(
            path,
            O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard fd >= 0 else {
            return nil
        }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1 else {
            Darwin.close(fd)
            return nil
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
