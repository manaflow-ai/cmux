public import Darwin
public import Foundation

/// Opens a log file for appending only when the file is a private regular
/// file owned by the expected user.
///
/// Debug logs live at predictable paths in the shared `/tmp` directory, where
/// another local user can plant a symbolic link or a hard link to one of this
/// user's files before cmux first writes there. This opener refuses to follow a
/// final-component symbolic link and, after opening, refuses anything that is
/// not a regular file owned by ``expectedOwnerID`` with exactly one link, so a
/// log line never lands in a file that the path's creator chose.
///
/// ```swift
/// guard let handle = OwnedFileAppendOpener().fileHandle(atPath: logPath) else { return }
/// defer { try? handle.close() }
/// try? handle.write(contentsOf: data)
/// ```
public struct OwnedFileAppendOpener: Sendable, Equatable {
    /// The user ID that must own the opened file.
    public let expectedOwnerID: uid_t
    /// The permission bits the opened file ends up with, whether it was
    /// created or already existed.
    public let creationMode: mode_t

    /// Creates an opener.
    ///
    /// - Parameters:
    ///   - expectedOwnerID: The user ID that must own the file. Defaults to
    ///     this process's effective user ID, the owner of any file it creates.
    ///   - creationMode: Permission bits for a newly created file. Defaults to
    ///     `0600` because debug logs can carry workspace details.
    public init(expectedOwnerID: uid_t = geteuid(), creationMode: mode_t = 0o600) {
        self.expectedOwnerID = expectedOwnerID
        self.creationMode = creationMode
    }

    /// Opens `path` for appending, creating it when missing.
    ///
    /// - Parameter path: The file to append to.
    /// - Returns: A write-only, append-mode, close-on-exec descriptor that the
    ///   caller must close, or `nil` when the path is a symbolic link, is not a
    ///   regular file, is owned by another user, has more than one link, or
    ///   cannot be narrowed to ``creationMode``.
    public func openDescriptor(atPath path: String) -> Int32? {
        // O_NONBLOCK makes a planted FIFO fail the open instead of blocking
        // until a reader appears; it has no effect on regular-file writes.
        let fd = open(
            path,
            O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
            creationMode
        )
        guard fd >= 0 else { return nil }
        var status = stat()
        guard fstat(fd, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == expectedOwnerID,
              status.st_nlink == 1 else {
            close(fd)
            return nil
        }
        // open(2) applies the creation mode only to a new file, so narrow a
        // file that an earlier build or the user left wider.
        if status.st_mode & 0o7777 != creationMode, fchmod(fd, creationMode) != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    /// Opens `path` for appending and wraps the descriptor in a handle that
    /// closes it on deallocation.
    ///
    /// - Parameter path: The file to append to.
    /// - Returns: The append handle, or `nil` when ``openDescriptor(atPath:)``
    ///   refuses the path.
    public func fileHandle(atPath path: String) -> FileHandle? {
        guard let fd = openDescriptor(atPath: path) else { return nil }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
